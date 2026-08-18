import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Embedded Pear Music signaling server — a pure-Dart port of
/// `server/src/index.js`.
///
/// It runs inside the app itself (auto-started on Windows AND Android, no
/// Node.js needed) so any device can act as the signaling host:
///   * the host device starts this server and connects to
///     `ws://localhost:8080` (the default server URL);
///   * every other device points its "Signaling server URL" at the host's LAN
///     IP (shown in Settings) — the exact same flow as before, minus running
///     `node server/src/index.js` by hand.
///
/// Feature parity with the Node server: device registration (+auth secrets),
/// pairing codes, presence, text + raw-binary relay (with `relay_ack`
/// pacing), un-pairing, control/rate limits, per-IP caps, register timeout,
/// relay byte budget, and persisted pairings/names/secrets.
///
/// NOTE on backpressure: the Node server holds `relay_ack` while a target's
/// outbound buffer is above a high-water mark. `dart:io` WebSocket does not
/// expose `bufferedAmount`, so this port acks after forwarding each frame and
/// relies on the client's existing per-chunk ack gating (one binary chunk in
/// flight per sender) to bound memory. Fine for the local/LAN host the
/// embedded server is for; the Node server keeps full backpressure for
/// internet relays.
class SignalingServer {
  SignalingServer({
    required this.port,
    this.host = '0.0.0.0',
    this.stateFile,
    this.onLog,
    this.advertiseName = 'Pear Music device',
    this.advertiseDeviceId,
    this.trustProxyHeaders = false,
  });

  final int port;
  final String host;
  final File? stateFile;
  final void Function(String message)? onLog;

  /// Whether to trust a client-supplied `X-Forwarded-For` header as the
  /// connecting IP. Only meaningful if this server is actually deployed
  /// behind a real reverse proxy (it isn't, for the embedded on-device
  /// server this app runs — see [_clientIp]). Defaults to false so a remote
  /// WebSocket client can't just claim to be any IP it likes.
  final bool trustProxyHeaders;

  /// Device identity advertised during LAN discovery (the name peers see).
  String advertiseName;
  String? advertiseDeviceId;

  // ---- Limits (mirror server/src/index.js) ----
  static const int maxPayload = 2 * 1024 * 1024; // 2 MB per frame
  // Text/control frames (register, manifest, etc.) had no size cap at all —
  // only binary chunk frames did. A single oversized text frame could spike
  // memory before the rate limiter or JSON decode ever runs, on what may
  // just be someone's phone. Generous enough for a very large library's
  // manifest, far below "unbounded".
  static const int maxTextPayload = 4 * 1024 * 1024; // 4 MB per text frame
  static const int maxConnsPerIp = 8;
  static const Duration registerTimeout = Duration(seconds: 10);
  static const int pairOpLimit = 10;
  static const Duration pairWindow = Duration(minutes: 1);
  static const int globalPairLimit = 60;
  static const Duration globalPairWindow = Duration(minutes: 1);
  static const int controlMsgLimit = 500;
  static const Duration controlWindow = Duration(seconds: 10);
  static const int relayBytesBudget = 2 * 1024 * 1024 * 1024; // 2 GB
  static const String codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const int codeLength = 6;
  static const Duration codeTtl = Duration(minutes: 10);
  static final RegExp codeRe = RegExp(r'^[A-HJ-NP-Z2-9]{6}$');
  static const Duration serverPingInterval = Duration(seconds: 30);

  // ---- Ghost-pair cleanup ----
  //
  // A "ghost" is a persisted pairing to a deviceId that will never come back —
  // typically because the device's identity was reset (a reinstall / "clear
  // data" gave it a NEW deviceId, so the OLD id is permanently dead). Without
  // cleanup these linger forever in the state file and in the client's Devices
  // list, and they resurrect via another host's persisted state after a
  // failover. Three mechanisms keep the pairing list honest:
  //   1. [offlineReportGrace]: an offline peer stops being REPORTED to clients
  //      once it hasn't been seen for this long, so the client drops it (and
  //      its shared songs) and stops re-reporting it. It re-syncs the moment
  //      the real device reconnects.
  //   2. Reconcile-on-register: a device that reports its pairing list is
  //      authoritative — offline peers it no longer reports are pruned, so an
  //      unpaired ghost can never be resurrected by another host's state.
  //   3. [staleAfter] GC: a persisted pairing where BOTH devices have been
  //      un-seen for this long is removed from the state file entirely.
  //   4. Unpair tombstones: mechanism #2 assumes the reporting device's list
  //      is trustworthy, but a device that was OFFLINE at the moment its peer
  //      unpaired it never learns that and keeps reporting the dead pairing
  //      forever — which used to make register()  silently RE-ADD it (the
  //      classic "ghost pairing": device A unpairs device B while B is
  //      offline, B is reachable again and reconnects/re-hosts, and the old
  //      pairing comes back on A's side too, or B is stuck forever showing
  //      "paired" to a peer that has no record of it at all). Every explicit
  //      unpair now leaves a persisted tombstone for [tombstoneTtl]; register()
  //      refuses to restore a tombstoned pair from a client's self-reported
  //      list and instead tells the client to drop it, so an unpair sticks
  //      even across the unpaired device's own restarts.
  static const Duration offlineReportGrace = Duration(days: 7);
  static const Duration staleAfter = Duration(days: 30);
  static const Duration tombstoneTtl = Duration(days: 30);
  static const Duration gcPeriod = Duration(hours: 6);

  // ---- LAN discovery (LocalSend-style) ----
  // A fixed multicast group in 224.0.0.0/24 (the range Android devices
  // reliably receive) plus an HTTP /discover endpoint as the subnet-scan
  // fallback. Peers find this server by either path.
  static const String multicastGroup = '224.0.0.173';
  static const String _probeType = 'peerm_probe';
  static const String _helloType = 'peerm_hello';
  RawDatagramSocket? _multicastSocket;
  Timer? _announceTimer;

  // ---- Runtime state ----
  final Map<String, _Conn> _devices = {}; // deviceId -> connection
  final Map<String, _Pairing> _pairingCodes = {}; // code -> host info
  final Map<String, String> _pendingBin = {}; // fromDeviceId -> toDeviceId
  final Map<String, int> _ipCounts = {}; // ip -> open connections
  final Map<String, _WindowCounter> _pairOps = {}; // per-device pair counter
  final _WindowCounter _globalPairOps =
      _WindowCounter(globalPairLimit, globalPairWindow);

  // ---- Persisted state (survives app restarts) ----
  final Map<String, Set<String>> _persistedPairs = {};
  final Map<String, String> _persistedNames = {};
  final Map<String, String> _persistedSecrets = {};
  final Map<String, DateTime> _persistedLastSeen = {};
  // Explicit-unpair tombstones, keyed by the pair (order-independent). See
  // "Ghost-pair cleanup" mechanism #4 above.
  final Map<String, DateTime> _pairTombstones = {};
  Timer? _gcTimer;

  static String _pairKey(String aId, String bId) =>
      aId.compareTo(bId) < 0 ? '$aId|$bId' : '$bId|$aId';

  void _tombstonePair(String aId, String bId) {
    _pairTombstones[_pairKey(aId, bId)] = DateTime.now();
  }

  bool _isTombstoned(String aId, String bId) =>
      _pairTombstones.containsKey(_pairKey(aId, bId));

  void _clearTombstone(String aId, String bId) {
    _pairTombstones.remove(_pairKey(aId, bId));
  }

  final Random _rng = Random.secure();
  HttpServer? _server;
  Timer? _codeExpiryTimer;
  bool _running = false;

  bool get isRunning => _running;
  int get boundPort => _server?.port ?? port;

  /// Best-effort LAN IPv4 of this device (what OTHER devices connect to).
  ///
  /// Resolved at [start] and refreshed every [_lanIpRefreshInterval] while the
  /// server runs. The advertised `ws://` URL MUST stay the address peers can
  /// actually reach us at — a stale address (e.g. the machine moved to a new
  /// hotspot with a different subnet) makes peers defer to a URL they can't
  /// connect to, so they fail, take over as host, re-discover, defer again…
  /// an endless host-flap loop.
  String? lanIp;
  Timer? _lanIpTimer;
  static const Duration _lanIpRefreshInterval = Duration(seconds: 20);

  void _log(String message) => onLog?.call(message);

  // ----------------------------------------------------------------------
  // Lifecycle
  // ----------------------------------------------------------------------

  Future<void> start() async {
    if (_running) return;
    _loadState();
    lanIp = await _resolveLanIp();
    _server = await HttpServer.bind(host, port);
    _server!.listen(_handleHttp);
    _codeExpiryTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      final now = DateTime.now();
      _pairingCodes.removeWhere((_, p) => now.difference(p.createdAt) > codeTtl);
    });
    // Keep the advertised LAN IP fresh so a network change (new hotspot,
    // different Wi-Fi) is picked up without restarting the server.
    _lanIpTimer = Timer.periodic(_lanIpRefreshInterval, (_) async {
      final fresh = await _resolveLanIp();
      if (fresh == null) return;
      if (fresh != lanIp) {
        _log('[discover] LAN IP changed: ${lanIp ?? '(none)'} -> $fresh');
        lanIp = fresh;
      }
    });
    // Clean up persisted pairings to long-gone devices (see ghost-pair notes).
    _gcStalePairings();
    _gcTimer = Timer.periodic(gcPeriod, (_) => _gcStalePairings());
    _running = true;
    _log('Pear Music signaling server listening on $host:$port (ws)');
    _log('  ws://localhost:$port   (other devices: ws://${lanIp ?? host}:$port)');
    if (stateFile != null) _log('  persistent state: ${stateFile!.path}');
    _startMulticast();
  }

  Future<void> stop() async {
    _running = false;
    _codeExpiryTimer?.cancel();
    _codeExpiryTimer = null;
    _gcTimer?.cancel();
    _gcTimer = null;
    _lanIpTimer?.cancel();
    _lanIpTimer = null;
    _announceTimer?.cancel();
    _announceTimer = null;
    try {
      _multicastSocket?.close();
    } catch (_) {}
    _multicastSocket = null;
    for (final conn in _devices.values) {
      try {
        conn.ws.close(1001, 'server stopping');
      } catch (_) {}
    }
    _devices.clear();
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  // ----------------------------------------------------------------------
  // HTTP + WebSocket entry points
  // ----------------------------------------------------------------------

  Future<void> _handleHttp(HttpRequest req) async {
    if (WebSocketTransformer.isUpgradeRequest(req)) {
      try {
        final ws = await WebSocketTransformer.upgrade(req);
        _handleConnection(ws, req);
      } catch (_) {
        // upgrade failed (e.g. mid-close); ignore
      }
      return;
    }
    final path = req.uri.path;
    if (path == '/' || path == '/health') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'ok': true,
        'service': 'pear-music-signaling',
        'devices': _devices.length,
        'time': DateTime.now().toIso8601String(),
      }));
      await req.response.close();
    } else if (path == '/discover') {
      // LAN discovery endpoint (subnet-scan fallback + QR-less joiner finds
      // this host). Mirrors the UDP multicast hello so both paths agree.
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(_helloJson()));
      await req.response.close();
    } else {
      req.response.statusCode = HttpStatus.notFound;
      req.response.write('Not found');
      await req.response.close();
    }
  }

  /// The `peerm_hello` payload used by both the `/discover` endpoint and the
  /// UDP multicast announcements.
  Map<String, dynamic> _helloJson() {
    final ip = lanIp ?? '127.0.0.1';
    return {
      'type': _helloType,
      'name': advertiseName,
      'deviceId': advertiseDeviceId,
      'url': 'ws://$ip:$boundPort',
    };
  }

  /// Joins the multicast group, answers `peerm_probe` messages with our hello
  /// (unicast back to the sender), and periodically announces ourselves so
  /// passive listeners see us. All best-effort: if the network/firewall drops
  /// multicast, discovery still works via the `/discover` subnet scan.
  void _startMulticast() {
    try {
      // reuseAddress only — reusePort is unsupported on Windows and would
      // surface as an unhandled socket error.
      RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      ).then((socket) {
        _multicastSocket = socket;
        try {
          socket.joinMulticast(InternetAddress(multicastGroup));
        } catch (_) {}
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          final dg = socket.receive();
          if (dg == null) return;
          final msg = utf8.decode(dg.data, allowMalformed: true).trim();
          if (msg.contains(_probeType)) {
            try {
              socket.send(
                utf8.encode(jsonEncode(_helloJson())),
                dg.address,
                dg.port,
              );
              _log('[discover] answered probe from ${dg.address.address}');
            } catch (_) {}
          }
        });
        _log('[discover] multicast listening on $multicastGroup:$port');
      }).catchError((Object e) {
        _log('[discover] multicast unavailable: $e');
      });
    } catch (_) {}
    _announceTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _sendAnnouncement();
    });
    _sendAnnouncement();
  }

  void _sendAnnouncement() {
    final socket = _multicastSocket;
    if (socket == null) return;
    try {
      socket.send(
        utf8.encode(jsonEncode(_helloJson())),
        InternetAddress(multicastGroup),
        port,
      );
    } catch (_) {}
  }

  void _handleConnection(WebSocket ws, HttpRequest req) {
    final conn = _Conn(ws, _clientIp(req));
    // Server-side liveness: dart:io auto-sends a ping every interval and
    // closes the socket if no pong arrives (mirrors the Node heartbeat that
    // terminates clients that miss two pings). The client also auto-pongs.
    ws.pingInterval = serverPingInterval;

    // Per-IP connection cap.
    final ip = conn.ip;
    final ipCurrent = _ipCounts[ip] ?? 0;
    if (ipCurrent >= maxConnsPerIp) {
      _log('[+] rejected connection from $ip ($ipCurrent already open)');
      try {
        ws.close(4002, 'too many connections');
      } catch (_) {}
      return;
    }
    _ipCounts[ip] = ipCurrent + 1;
    _log('[+] client connected ($ip)');

    // Close connections that never register (bots occupying a slot).
    final registerTimer = Timer(registerTimeout, () {
      if (conn.deviceId == null) {
        try {
          ws.close(4004, 'register timeout');
        } catch (_) {}
      }
    });

    ws.listen(
      (data) => _handleMessage(conn, data).ignore(),
      onError: (_) {},
      onDone: () {
        registerTimer.cancel();
        _onDisconnect(conn);
      },
    );
  }

  String _clientIp(HttpRequest req) {
    // Behind a REAL reverse proxy the true client IP is in x-forwarded-for.
    // This embedded, on-device server is normally reached directly (it's a
    // zero-config LAN server, not something deployed behind a proxy), so any
    // WebSocket client could set this header to whatever it likes. Only
    // trust it when explicitly opted in via [trustProxyHeaders]; otherwise
    // always use the real TCP peer address, which a client cannot spoof.
    if (trustProxyHeaders) {
      final xff = req.headers.value('x-forwarded-for');
      if (xff != null && xff.trim().isNotEmpty) {
        return xff.split(',').first.trim();
      }
    }
    return req.connectionInfo?.remoteAddress.address ?? 'unknown';
  }

  void _onDisconnect(_Conn conn) {
    _log('[server] connection closed code=${conn.ws.closeCode} reason=${conn.ws.closeReason}');
    final remaining = (_ipCounts[conn.ip] ?? 1) - 1;
    if (remaining <= 0) {
      _ipCounts.remove(conn.ip);
    } else {
      _ipCounts[conn.ip] = remaining;
    }
    final id = conn.deviceId;
    if (id != null && identical(_devices[id], conn)) {
      conn.online = false;
      _pendingBin.remove(id); // drop any half-sent relay route
      _notifyPresence(id);
      final name = conn.name;
      _log('[-] $name disconnected');
      _devices.remove(id);
    }
  }

  // ----------------------------------------------------------------------
  // Message handling (port of the Node `switch (msg.type)`)
  // ----------------------------------------------------------------------

  Future<void> _handleMessage(_Conn conn, dynamic data) async {
    // Binary frame = the body of a relayed chunk. Its route was announced by
    // the preceding {t:'bin'} relay marker from this device.
    if (data is! String) {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data as List<int>);
      if (bytes.length > maxPayload) {
        try {
          conn.ws.close(1009, 'message too big');
        } catch (_) {}
        return;
      }
      final id = conn.deviceId;
      if (id != null) {
        conn.relayedBytes += bytes.length;
        if (conn.relayedBytes > relayBytesBudget) {
          _log('[relay] ${conn.name} exceeded relay byte budget; closing');
          try {
            conn.ws.close(4003, 'relay budget exceeded');
          } catch (_) {}
          return;
        }
        final to = _pendingBin[id];
        if (to != null) {
          _pendingBin.remove(id);
          if (conn.pairings.contains(to)) {
            final target = _devices[to];
            if (target != null) {
              target.send(bytes);
              conn.send({'type': 'relay_ack'});
            }
          }
        }
      }
      return;
    }

    // Text (control) frame: bound its size before doing any work on it (rate
    // limiting, JSON decode) — same idea as the binary cap above, just for
    // text frames, which previously had no limit at all.
    if (data.length > maxTextPayload) {
      try {
        conn.ws.close(1009, 'message too big');
      } catch (_) {}
      return;
    }

    // Text message: rate-limit control traffic (binary frames are excluded —
    // they are already paced by relay_ack).
    if (!conn.controlLimiter.allow()) {
      _log('[rate] ${conn.name} — control message flood');
      try {
        conn.ws.close(4003, 'rate limited');
      } catch (_) {}
      return;
    }

    Map<String, dynamic>? msg;
    try {
      final decoded = jsonDecode(data);
      msg = decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return; // not JSON — ignore
    }
    if (msg == null) return;

    switch (msg['type']) {
      // ---- Register / re-register ----
      case 'register':
        await _onRegister(conn, msg);
        break;

      // ---- Host creates a pairing code ----
      case 'create_pairing':
        final id = conn.deviceId;
        if (id == null) return;
        if (!_canDoPairOp(id)) {
          conn.send({
            'type': 'error',
            'message': 'Too many pairing operations. Please wait a minute and try again.',
          });
          return;
        }
        // Invalidate any previous pending code for this device.
        _pairingCodes.removeWhere((_, p) => p.hostDeviceId == id);
        final code = _generateCode();
        _pairingCodes[code] = _Pairing(id, DateTime.now());
        conn.send({
          'type': 'pairing_created',
          'code': code,
          'expiresIn': codeTtl.inSeconds,
        });
        _log('[code] ${conn.name} created pairing code $code');
        break;

      // ---- Peer enters a code to pair ----
      case 'pair_with_code':
        await _onPairWithCode(conn, msg);
        break;

      // ---- Relay a message between paired devices ----
      case 'signal': {
        final id = conn.deviceId;
        if (id == null) return;
        final to = (msg['to'] as String? ?? '').trim();
        if (!conn.pairings.contains(to)) return; // must be paired
        final target = _devices[to];
        if (target == null) return;
        target.send({'type': 'signal', 'from': id, 'data': msg['data']});
        break;
      }

      // ---- Relay file-sync data between paired devices ----
      case 'relay': {
        final id = conn.deviceId;
        if (id == null) return;
        final to = (msg['to'] as String? ?? '').trim();
        if (!conn.pairings.contains(to)) return; // must be paired
        final target = _devices[to];
        if (target == null) return;
        final data = msg['data'];
        final t = (data is Map<String, dynamic>) ? data['t'] : null;
        if (t == 'bin') {
          final d = (data is Map<String, dynamic>) ? data['d'] : null;
          if (d is String) {
            // Legacy: a base64 chunk inside the JSON envelope.
            target.send({'type': 'relay', 'from': id, 'data': data});
          } else {
            // New: the chunk body follows as a raw binary frame. Tell the
            // target which peer the frame is from, remember the route so the
            // frame handler can forward the bytes unchanged, and PRESERVE the
            // `e:1` encryption flag — the receiver must know to decrypt the
            // frame. (This was dropped before, which broke sync once E2E
            // encryption actually turned on.)
            final e = (data is Map<String, dynamic>) ? data['e'] : null;
            target.send({
              'type': 'relay',
              'from': id,
              'data': {'t': 'bin', if (e == 1) 'e': 1},
            });
            _pendingBin[id] = to;
          }
        } else {
          target.send({'type': 'relay', 'from': id, 'data': data});
          if (t == 'text') {
            _log('[relay] ${conn.name} -> ${target.name} (text)');
          }
        }
        break;
      }

      // ---- Unpair ----
      case 'unpair': {
        final id = conn.deviceId;
        if (id == null) return;
        final peerId = (msg['peerId'] as String? ?? '').trim();
        if (peerId.isEmpty) return;
        // Remove the pairing regardless of whether THIS connection currently
        // lists it — the client may be clearing a stale/phantom entry. The
        // notify below makes sure the requesting client removes it locally
        // even if the server had already lost the pairing.
        final hadPairing = conn.pairings.contains(peerId) ||
            (_persistedPairs[id]?.contains(peerId) ?? false);
        _removePair(id, peerId);
        final peer = _peerInfo(peerId);
        conn.send({
          'type': 'unpaired',
          'peer': peer != null
              ? {'deviceId': peer['deviceId'], 'deviceName': peer['deviceName']}
              : {'deviceId': peerId},
        });
        final me = _peerInfo(id);
        _devices[peerId]?.send({
          'type': 'unpaired',
          'peer': me != null
              ? {'deviceId': me['deviceId'], 'deviceName': me['deviceName']}
              : {'deviceId': id},
        });
        _log(hadPairing
            ? '[unpair] ${conn.name} removed ${peer?['deviceName'] ?? peerId}'
            : '[unpair] ${conn.name} cleared stale pairing ${peer?['deviceName'] ?? peerId}');
        break;
      }

      // ---- Ask for current state (e.g. after reconnect) ----
      case 'get_state':
        final id = conn.deviceId;
        if (id == null) return;
        _sendState(conn);
        break;

      // ---- Client heartbeat ----
      case 'ping':
        conn.send({'type': 'pong'});
        break;

      default:
        conn.send({'type': 'error', 'message': 'Unknown message type: ${msg['type']}'});
    }
  }

  Future<void> _onRegister(_Conn conn, Map<String, dynamic> msg) async {
    final id = (msg['deviceId'] as String? ?? '').trim();
    final rawName = (msg['deviceName'] as String? ?? 'Unnamed device').trim();
    final name = rawName.length <= 40 ? rawName : rawName.substring(0, 40);
    final givenSecret = msg['secret'] as String? ?? '';

    if (id.isEmpty) {
      conn.send({'type': 'error', 'message': 'deviceId is required'});
      return;
    }

    // The host's OWN device is always authorized on its own server. During a
    // host failover the client secret was issued by the PREVIOUS host's server
    // and may not match the secret persisted in THIS host's state file - so
    // instead of locking itself out, adopt the client's secret (or re-bind a
    // fresh one) and let it in.
    //
    // IMPORTANT: `advertiseDeviceId` is NOT a secret — it's broadcast in the
    // clear over LAN discovery (multicast hello + the /discover endpoint) so
    // other devices can find this host to pair with it. Matching it alone is
    // not proof this connection is really the host's own app; anyone on the
    // LAN could otherwise claim it and skip the secret check entirely. The
    // host's own app only ever reconnects to itself over loopback
    // (`ws://localhost:<port>` — see AppController._ensureConnection /
    // _takeOverAsHost), so this bypass is additionally restricted to
    // loopback connections. A non-loopback connection claiming the same id
    // still goes through the normal secret check in the `else` branch below.
    final isLoopback = conn.ip == '127.0.0.1' || conn.ip == '::1';
    final isOwnDevice =
        advertiseDeviceId != null && advertiseDeviceId == id && isLoopback;
    if (isOwnDevice) {
      _persistedSecrets[id] = givenSecret.isNotEmpty ? givenSecret : _randomSecret();
      _saveState();
    } else {
      // Device-authentication secret: a wrong secret is rejected, an empty
      // secret re-binds a fresh one (never locks out an upgrade/reinstall).
      final existingSecret = _persistedSecrets[id];
      if (existingSecret != null) {
        if (givenSecret.isNotEmpty && givenSecret != existingSecret) {
          _log('[auth] rejected register for $id (mismatched secret)');
          conn.send({'type': 'error', 'message': 'unauthorized'});
          try {
            conn.ws.close(4001, 'unauthorized');
          } catch (_) {}
          return;
        }
        if (givenSecret.isEmpty) {
          _persistedSecrets[id] = _randomSecret();
          _saveState();
        }
      } else {
        _persistedSecrets[id] = givenSecret.isNotEmpty ? givenSecret : _randomSecret();
        _saveState();
      }
    }

    // If this device was connected elsewhere, kick the old socket.
    final existing = _devices[id];
    if (existing != null && !identical(existing.ws, conn.ws)) {
      try {
        existing.ws.close(4001, 'replaced');
      } catch (_) {}
    }

    conn.deviceId = id;
    conn.name = name;
    conn.online = true;
    // Seed pairings from persistence so a restart doesn't unpair devices.
    conn.pairings
      ..clear()
      ..addAll(existing?.pairings ?? const <String>{})
      ..addAll(_persistedPairs[id] ?? const <String>{});
    // Restore pairings this device reports — used after a HOST FAILOVER: the
    // new host learns the existing pairing from the connecting client instead
    // of starting empty (which would unpair them and wipe shared songs).
    final restored = msg['pairings'];
    final reportedIds = <String>{};
    // Peers this device still thinks it's paired with, but that were
    // EXPLICITLY unpaired (by the other side, or by a previous host) while
    // this device was offline. We must not let its stale self-report
    // resurrect them — instead we tell it to drop them below.
    final revokedPeers = <Map<String, String>>[];
    var restoredAny = false;
    if (restored is List) {
      for (final item in restored) {
        String? pid;
        String? pname;
        if (item is String) {
          pid = item;
        } else if (item is Map) {
          pid = item['deviceId'] as String?;
          pname = item['deviceName'] as String?;
        }
        if (pid == null || pid.isEmpty || pid == id) continue;
        if (_isTombstoned(id, pid)) {
          conn.pairings.remove(pid);
          _removePersistedPair(id, pid);
          revokedPeers.add({
            'deviceId': pid,
            'deviceName': pname ?? _persistedNames[pid] ?? 'Unnamed device',
          });
          continue; // do NOT add to reportedIds — a tombstoned pair must not
          // survive the reconcile step below either.
        }
        reportedIds.add(pid);
        if (conn.pairings.add(pid)) {
          _persistedPairs.putIfAbsent(id, () => <String>{}).add(pid);
          _persistedPairs.putIfAbsent(pid, () => <String>{}).add(id);
          restoredAny = true;
        }
        if (pname != null && pname.isNotEmpty) {
          _persistedNames[pid] = pname;
        }
      }
    }
    _devices[id] = conn;

    // Remember the name so offline peers still show it after a restart, and
    // record that this device is alive right now (drives ghost cleanup).
    final lastSeenChanged = _updateLastSeen(id);
    if (_persistedNames[id] != name) {
      _persistedNames[id] = name;
      _saveState();
    } else if (restoredAny || lastSeenChanged) {
      _saveState();
    }

    if (restored is List) {
      // The client reported its authoritative pairing list (the app ALWAYS
      // sends `pairings`, possibly empty). Reconcile this device's pairings to
      // exactly what it reports plus currently-online peers that list it.
      // Offline peers it no longer reports are pruned — this is what makes an
      // unpair stick forever (a ghost can't be resurrected by another host's
      // persisted state) and what removes pairings to devices whose identity
      // was reset.
      final onlineListingUs = <String>{
        for (final e in _devices.entries)
          if (e.value.online && e.value.pairings.contains(id)) e.key,
      };
      final keep = {...reportedIds, ...onlineListingUs};
      for (final peerId in conn.pairings.toList()) {
        if (!keep.contains(peerId)) {
          conn.pairings.remove(peerId);
          _removePersistedPair(id, peerId);
          _saveState();
        }
      }
    } else {
      // Legacy path (client didn't send a pairing list): keep persisted
      // pairings to offline peers (they survive restarts), but drop peers that
      // are neither registered nor persisted (truly stale/foreign deviceIds).
      final persisted = _persistedPairs[id] ?? const <String>{};
      for (final peerId in conn.pairings.toList()) {
        if (!_devices.containsKey(peerId) && !persisted.contains(peerId)) {
          conn.pairings.remove(peerId);
        }
      }
    }

    conn.send({
      'type': 'registered',
      'deviceId': id,
      'secret': _persistedSecrets[id],
    });
    // Explicitly correct any ghost pairings before sending state, so the
    // client's local paired-device cache (and shared songs from that peer)
    // are cleared immediately instead of silently dropping out of `state`.
    for (final peer in revokedPeers) {
      conn.send({'type': 'unpaired', 'peer': peer});
      _log('[unpair] told ${conn.name} to drop stale pairing '
          '${peer['deviceName']} (${peer['deviceId']}) — tombstoned');
    }
    _sendState(conn);
    _notifyPresence(id);
    _log('[register] $name ($id)');
  }

  Future<void> _onPairWithCode(_Conn conn, Map<String, dynamic> msg) async {
    final id = conn.deviceId;
    if (id == null) return;
    if (!_canDoPairOp(id)) {
      conn.send({
        'type': 'error',
        'message': 'Too many pairing attempts. Please wait a minute and try again.',
      });
      return;
    }
    if (!_globalPairOps.allow()) {
      conn.send({
        'type': 'error',
        'message': 'Too many pairing attempts. Please wait a minute and try again.',
      });
      return;
    }
    final code = (msg['code'] as String? ?? '').trim().toUpperCase();
    if (!codeRe.hasMatch(code)) {
      conn.send({'type': 'error', 'message': 'Invalid or expired pairing code.'});
      return;
    }
    final pending = _pairingCodes[code];
    if (pending == null) {
      conn.send({'type': 'error', 'message': 'Invalid or expired pairing code.'});
      return;
    }
    if (pending.hostDeviceId == id) {
      conn.send({'type': 'error', 'message': 'You cannot pair with yourself.'});
      return;
    }
    _pairingCodes.remove(code); // single use
    _addPair(id, pending.hostDeviceId);
    final me = _peerInfo(id);
    final host = _peerInfo(pending.hostDeviceId);
    conn.send({'type': 'paired', 'peer': host});
    _devices[pending.hostDeviceId]?.send({'type': 'paired', 'peer': me});
    _notifyPresence(id);
    _notifyPresence(pending.hostDeviceId);
    _log('[pair] ${me?['deviceName']} <-> ${host?['deviceName']}');
  }

  // ----------------------------------------------------------------------
  // Helpers (port of the Node helpers)
  // ----------------------------------------------------------------------

  bool _canDoPairOp(String deviceId) {
    final now = DateTime.now();
    var rec = _pairOps[deviceId];
    if (rec == null || now.difference(rec.windowStart) > pairWindow) {
      rec = _WindowCounter(pairOpLimit, pairWindow);
      _pairOps[deviceId] = rec;
    }
    return rec.allow();
  }

  String _generateCode() {
    final buf = StringBuffer();
    for (var i = 0; i < codeLength; i++) {
      buf.write(codeAlphabet[_rng.nextInt(codeAlphabet.length)]);
    }
    return buf.toString();
  }

  String _randomSecret() {
    final bytes = List<int>.generate(24, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _addPair(String aId, String bId) {
    _pairingsOf(aId).add(bId);
    _pairingsOf(bId).add(aId);
    _addPersistedPair(aId, bId);
    // A fresh, deliberate re-pair always wins over a stale tombstone from a
    // previous unpair — otherwise two devices could never re-pair after
    // unpairing once.
    _clearTombstone(aId, bId);
    _saveState();
  }

  void _removePair(String aId, String bId) {
    _pairingsOf(aId).remove(bId);
    _pairingsOf(bId).remove(aId);
    _removePersistedPair(aId, bId);
    // Record that this pair was EXPLICITLY broken, so a device that was
    // offline at the time (and still reports the old pairing when it comes
    // back) can't silently resurrect it — see mechanism #4 above.
    _tombstonePair(aId, bId);
    _saveState();
  }

  Set<String> _pairingsOf(String deviceId) {
    final d = _devices[deviceId];
    if (d == null) return const <String>{};
    return d.pairings;
  }

  void _addPersistedPair(String aId, String bId) {
    _persistedPairs.putIfAbsent(aId, () => <String>{}).add(bId);
    _persistedPairs.putIfAbsent(bId, () => <String>{}).add(aId);
  }

  void _removePersistedPair(String aId, String bId) {
    final a = _persistedPairs[aId];
    if (a != null) {
      a.remove(bId);
      if (a.isEmpty) _persistedPairs.remove(aId);
    }
    final b = _persistedPairs[bId];
    if (b != null) {
      b.remove(aId);
      if (b.isEmpty) _persistedPairs.remove(bId);
    }
  }

  /// Records that [id] is online right now and returns true when its last-seen
  /// moved by more than a minute (so we don't rewrite the state file on every
  /// reconnect). Devices we've never seen are seeded with now.
  bool _updateLastSeen(String id) {
    final now = DateTime.now();
    final last = _persistedLastSeen[id];
    final changed =
        last == null || now.difference(last) > const Duration(minutes: 1);
    _persistedLastSeen[id] = now;
    return changed;
  }

  /// Removes persisted pairings where BOTH devices have been un-seen for
  /// [staleAfter] — pure hygiene for pairings whose devices are both gone
  /// (nothing can ever reconnect to re-confirm them). Ghosts where ONE side is
  /// still active are handled by the report-grace + reconcile-on-register
  /// instead (so an active device's shared songs are never wiped by this).
  void _gcStalePairings() {
    final now = DateTime.now();
    final stalePairs = <(String, String)>[];
    _persistedPairs.forEach((aId, bSet) {
      for (final bId in bSet) {
        if (_isStale(aId, now) && _isStale(bId, now)) {
          stalePairs.add((aId, bId));
        }
      }
    });
    final expiredTombstones = <String>[];
    _pairTombstones.forEach((key, at) {
      if (now.difference(at) > tombstoneTtl) expiredTombstones.add(key);
    });
    for (final key in expiredTombstones) {
      _pairTombstones.remove(key);
    }

    if (stalePairs.isEmpty && expiredTombstones.isEmpty) return;
    for (final (a, b) in stalePairs) {
      _removePersistedPair(a, b);
    }
    _saveState();
    if (stalePairs.isNotEmpty) {
      _log('[persist] cleaned ${stalePairs.length} stale pairing(s)');
    }
    if (expiredTombstones.isNotEmpty) {
      _log('[persist] expired ${expiredTombstones.length} unpair tombstone(s)');
    }
  }

  bool _isStale(String id, DateTime now) {
    final last = _persistedLastSeen[id];
    // A device we've never seen is never assumed dead (could be a fresh host
    // restoring an offline pairing).
    if (last == null) return false;
    return now.difference(last) > staleAfter;
  }

  Map<String, dynamic>? _peerInfo(String id) {
    final d = _devices[id];
    if (d != null) return {'deviceId': id, 'deviceName': d.name, 'online': d.online};
    // Offline but still paired (e.g. after a restart): use the last known
    // name so the pairing survives and the client keeps its shared songs.
    final name = _persistedNames[id];
    if (name != null) return {'deviceId': id, 'deviceName': name, 'online': false};
    // A pairing we know about (restored after a host change) whose device
    // hasn't reconnected yet — keep it visible so a failover never looks like
    // an unpair (which would show '0 paired' on the client).
    if (_persistedPairs.containsKey(id)) {
      return {'deviceId': id, 'deviceName': 'Unknown device', 'online': false};
    }
    return null;
  }

  void _sendState(_Conn conn) {
    final now = DateTime.now();
    final pairings = conn.pairings
        .map(_peerInfo)
        .whereType<Map<String, dynamic>>()
        .where((p) {
          if (p['online'] == true) return true;
          // Offline peer: report it only if we've seen it recently. A device
          // that has been gone beyond [offlineReportGrace] is treated as gone —
          // the client drops it (and its shared songs) and stops re-reporting
          // it, so ghosts clean themselves up. A peer we've never seen (e.g. a
          // pairing restored on a fresh host before the peer reconnects) is
          // kept — the client's reported list is trusted. The real device
          // re-syncs everything the moment it reconnects.
          final id = p['deviceId'] as String;
          final last = _persistedLastSeen[id];
          if (last == null) return true;
          return now.difference(last) <= offlineReportGrace;
        })
        .map((p) => {
              'deviceId': p['deviceId'],
              'deviceName': p['deviceName'],
              'online': p['online'],
            })
        .toList();
    conn.send({'type': 'state', 'deviceId': conn.deviceId, 'pairings': pairings});
  }

  void _notifyPresence(String deviceId) {
    final online = _devices[deviceId]?.online ?? false;
    for (final peerId in _pairingsOf(deviceId)) {
      final peer = _devices[peerId];
      if (peer != null) {
        peer.send({
          'type': 'peer_status',
          'peerId': deviceId,
          'online': online,
        });
      }
    }
  }

  // ---- Persistence ----
  void _saveState() {
    final file = stateFile;
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      final pairs = <List<String>>[];
      final seen = <String>{};
      _persistedPairs.forEach((aId, bSet) {
        for (final bId in bSet) {
          final key = aId.compareTo(bId) < 0 ? '$aId|$bId' : '$bId|$aId';
          if (seen.contains(key)) continue;
          seen.add(key);
          pairs.add([aId, bId]);
        }
      });
      file.writeAsStringSync(jsonEncode({
        'pairings': pairs,
        'names': _persistedNames,
        'secrets': _persistedSecrets,
        'lastSeen': {
          for (final e in _persistedLastSeen.entries)
            e.key: e.value.toIso8601String(),
        },
        'tombstones': {
          for (final e in _pairTombstones.entries)
            e.key: e.value.toIso8601String(),
        },
      }));
    } catch (e) {
      _log('[persist] failed to save state: $e');
    }
  }

  void _loadState() {
    final file = stateFile;
    if (file == null || !file.existsSync()) return;
    try {
      final data = jsonDecode(file.readAsStringSync());
      if (data is! Map<String, dynamic>) return;
      final pairings = data['pairings'];
      if (pairings is List) {
        for (final entry in pairings) {
          if (entry is! List || entry.length != 2) continue;
          final a = entry[0];
          final b = entry[1];
          if (a is String && a.isNotEmpty && b is String && b.isNotEmpty) {
            _addPersistedPair(a, b);
          }
        }
      }
      final names = data['names'];
      if (names is Map) {
        names.forEach((id, name) {
          if (id is String && id.isNotEmpty && name is String) {
            _persistedNames[id] = name;
          }
        });
      }
      final secrets = data['secrets'];
      if (secrets is Map) {
        secrets.forEach((id, secret) {
          if (id is String && id.isNotEmpty && secret is String && secret.isNotEmpty) {
            _persistedSecrets[id] = secret;
          }
        });
      }
      final lastSeen = data['lastSeen'];
      if (lastSeen is Map) {
        lastSeen.forEach((id, ts) {
          if (id is String && id.isNotEmpty && ts is String) {
            final t = DateTime.tryParse(ts);
            if (t != null) _persistedLastSeen[id] = t;
          }
        });
      }
      final tombstones = data['tombstones'];
      if (tombstones is Map) {
        tombstones.forEach((key, ts) {
          if (key is String && key.isNotEmpty && ts is String) {
            final t = DateTime.tryParse(ts);
            if (t != null) _pairTombstones[key] = t;
          }
        });
      }
      // First run with lastSeen tracking (or an old state file without it):
      // seed every known device from the file's mtime so nothing is instantly
      // treated as stale/gone on upgrade. This gives the ghost-cleanup grace a
      // fresh start for every existing device.
      final known = <String>{
        ..._persistedNames.keys,
        ..._persistedPairs.keys,
      };
      if (known.isNotEmpty) {
        final seed = file.lastModifiedSync();
        for (final id in known) {
          _persistedLastSeen.putIfAbsent(id, () => seed);
        }
      }
      _log('[persist] loaded ${_persistedPairs.length} device(s) with pairings, '
          '${_persistedSecrets.length} with secrets');
    } catch (e) {
      _log('[persist] failed to load state: $e');
    }
  }

  // ---- LAN IP resolution ----
  Future<String?> _resolveLanIp() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      // Prefer a private-range address peers can actually reach: skip APIPA
      // link-local (169.254.x — never routable) and CGNAT (100.64.0.0/10 —
      // used by Tailscale/VPN adapters, which a phone on the same Wi-Fi can't
      // reach). This keeps the advertised ws:// URL pointing at the real LAN
      // interface even when virtual adapters are present.
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final a = addr.address;
          if (a.isEmpty || a == '0.0.0.0') continue;
          if (_isLinkLocal(a) || _isCgnat(a)) continue;
          if (_isPrivateIpv4(a)) return a;
        }
      }
      // Fallback: first non-loopback, non-link-local address.
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final a = addr.address;
          if (a.isEmpty || a == '0.0.0.0') continue;
          if (addr.isLoopback || _isLinkLocal(a) || _isCgnat(a)) continue;
          return a;
        }
      }
    } catch (_) {}
    return null;
  }

  static bool _isLinkLocal(String s) => s.startsWith('169.254.');

  /// Carrier-Grade NAT 100.64.0.0/10 — Tailscale and some VPNs use it; a peer
  /// on the LAN can't reach these, so never advertise one.
  static bool _isCgnat(String s) {
    final m = RegExp(r'^100\.(\d{1,3})\.').firstMatch(s);
    if (m == null) return false;
    final b = int.tryParse(m[1]!) ?? -1;
    return b >= 64 && b <= 127;
  }

  static bool _isPrivateIpv4(String s) {
    return s.startsWith('10.') ||
        s.startsWith('192.168.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(s);
  }
}

// ----------------------------------------------------------------------
// Internal types
// ----------------------------------------------------------------------

class _Conn {
  _Conn(this.ws, this.ip);

  final WebSocket ws;
  final String ip;
  final Set<String> pairings = {};
  final _WindowCounter controlLimiter =
      _WindowCounter(SignalingServer.controlMsgLimit, SignalingServer.controlWindow);

  String? deviceId;
  String name = 'Unnamed device';
  bool online = false;
  int relayedBytes = 0;

  /// Fire-and-forget send guarded against closed sockets. Text messages
  /// (Map) are JSON-encoded; binary frames (`List<int>`, e.g. `Uint8List`) are
  /// passed through as-is. The client paces relayed binary chunks with
  /// `relay_ack`, which bounds per-sender memory.
  void send(Object message) {
    if (ws.readyState != WebSocket.open) return;
    try {
      if (message is String || message is List<int>) {
        ws.add(message);
      } else {
        ws.add(jsonEncode(message));
      }
    } catch (_) {
      // socket raced to closed — ignore
    }
  }
}

class _Pairing {
  _Pairing(this.hostDeviceId, this.createdAt);
  final String hostDeviceId;
  final DateTime createdAt;
}

/// Sliding-window counter (port of `makeWindowCounter`).
class _WindowCounter {
  _WindowCounter(this.limit, this.window);
  final int limit;
  final Duration window;
  int _count = 0;
  DateTime _windowStart = DateTime.now();

  DateTime get windowStart => _windowStart;

  bool allow() {
    final now = DateTime.now();
    if (now.difference(_windowStart) > window) {
      _windowStart = now;
      _count = 0;
    }
    _count++;
    return _count <= limit;
  }
}
