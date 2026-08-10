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
  });

  final int port;
  final String host;
  final File? stateFile;
  final void Function(String message)? onLog;

  // ---- Limits (mirror server/src/index.js) ----
  static const int maxPayload = 2 * 1024 * 1024; // 2 MB per frame
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

  final Random _rng = Random.secure();
  HttpServer? _server;
  Timer? _codeExpiryTimer;
  bool _running = false;

  bool get isRunning => _running;
  int get boundPort => _server?.port ?? port;

  /// Best-effort LAN IPv4 of this device (what OTHER devices connect to).
  /// Filled in [start]; null if it could not be resolved.
  String? lanIp;

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
    _running = true;
    _log('Pear Music signaling server listening on $host:$port (ws)');
    _log('  ws://localhost:$port   (other devices: ws://${lanIp ?? host}:$port)');
    if (stateFile != null) _log('  persistent state: ${stateFile!.path}');
  }

  Future<void> stop() async {
    _running = false;
    _codeExpiryTimer?.cancel();
    _codeExpiryTimer = null;
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
    } else {
      req.response.statusCode = HttpStatus.notFound;
      req.response.write('Not found');
      await req.response.close();
    }
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
    // Behind a proxy the real IP is in x-forwarded-for.
    final xff = req.headers.value('x-forwarded-for');
    if (xff != null && xff.trim().isNotEmpty) {
      return xff.split(',').first.trim();
    }
    return req.connectionInfo?.remoteAddress.address ?? 'unknown';
  }

  void _onDisconnect(_Conn conn) {
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
            // target which peer the frame is from, then remember the route so
            // the frame handler can forward the bytes unchanged.
            target.send({'type': 'relay', 'from': id, 'data': {'t': 'bin'}});
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
        if (!conn.pairings.contains(peerId)) return;
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
        _log('[unpair] ${conn.name} removed ${peer?['deviceName'] ?? peerId}');
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
    _devices[id] = conn;

    // Remember the name so offline peers still show it after a restart.
    if (_persistedNames[id] != name) {
      _persistedNames[id] = name;
      _saveState();
    }

    // Drop pairings to peers that are neither registered nor persisted
    // (truly stale/foreign deviceIds). Persisted pairings to offline peers
    // are kept so they survive restarts.
    final persisted = _persistedPairs[id] ?? const <String>{};
    for (final peerId in conn.pairings.toList()) {
      if (!_devices.containsKey(peerId) && !persisted.contains(peerId)) {
        conn.pairings.remove(peerId);
      }
    }

    conn.send({
      'type': 'registered',
      'deviceId': id,
      'secret': _persistedSecrets[id],
    });
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
    _saveState();
  }

  void _removePair(String aId, String bId) {
    _pairingsOf(aId).remove(bId);
    _pairingsOf(bId).remove(aId);
    _removePersistedPair(aId, bId);
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

  Map<String, dynamic>? _peerInfo(String id) {
    final d = _devices[id];
    if (d != null) return {'deviceId': id, 'deviceName': d.name, 'online': d.online};
    // Offline but still paired (e.g. after a restart): use the last known
    // name so the pairing survives and the client keeps its shared songs.
    final name = _persistedNames[id];
    if (name != null) return {'deviceId': id, 'deviceName': name, 'online': false};
    return null;
  }

  void _sendState(_Conn conn) {
    final pairings = conn.pairings
        .map(_peerInfo)
        .whereType<Map<String, dynamic>>()
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
      // Prefer a private-range address (most common for a phone hotspot /
      // home router).
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (_isPrivateIpv4(addr.address)) return addr.address;
        }
      }
      // Fallback: first non-loopback address.
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
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
