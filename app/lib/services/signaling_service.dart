import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'identity_service.dart';

/// WebSocket client for the Pear Music signaling server.
///
/// Handles registration, pairing codes, WebRTC signal relay and presence, with
/// automatic exponential-backoff reconnection (plus jitter so a fleet of
/// devices doesn't reconnect in lockstep). All incoming server messages are
/// exposed through [stream]; raw relayed binary frames are surfaced there as
/// `_local` events with `event == 'binary'`.
class SignalingService {
  final IdentityService identity;

  SignalingService(this.identity) {
    // Generate the ephemeral X25519 keypair up front (fire-and-forget). It must
    // exist BEFORE any peer `hello` is sent or received - otherwise no hello
    // ever carries our public key, so neither side can derive the shared key
    // and relay encryption silently stays off.
    unawaited(ensureE2E());
  }

  final _incoming = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get stream => _incoming.stream;

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _manualStop = false;
  bool _connected = false;
  int _attempt = 0;

  /// Client heartbeat. We send a `ping` periodically and treat the connection
  /// as dead if the server stops responding — so a server that dies without a
  /// clean close (restart, crashed, half-open link) is detected and reconnected
  /// instead of leaving the app in a fake "connected" state that does nothing.
  static const _pingInterval = Duration(seconds: 15);
  static const _deadAfter = Duration(seconds: 45);
  Timer? _pingTimer;
  DateTime _lastServerActivity = DateTime.now();

  /// Bumped on every [stop]/[start] so a stale in-flight connect attempt can
  /// never resurrect a connection that was intentionally stopped.
  int _generation = 0;

  /// True only once the WebSocket is actually open (not merely created).
  bool get isConnected => _connected;

  // ---- Relay binary flow control ----
  //
  // Binary chunks travel as a JSON marker followed by a raw binary frame. To
  // keep the marker/frame pair glued together AND get real backpressure, only
  // one binary sequence is in flight at a time: we send marker+frame, then
  // wait for the server's `relay_ack`. The server only acks once it has
  // relayed the frame, and it delays the ack if the receiving peer is slow —
  // so a large file sync can never blow up memory on either side.
  Future<void> _relayLock = Future<void>.value();
  Completer<void>? _pendingRelayAck;
  Timer? _relayAckTimeout;

  // ---- End-to-end relay encryption ----
  //
  // The relay server sees every byte that passes through it, so file sync over
  // the relay is encrypted device-to-device. Each device creates an ephemeral
  // X25519 keypair; the public key is exchanged in the `hello` handshake on the
  // relay itself (public keys aren't secret). Both sides derive the SAME
  // AES-256 key from the shared secret, so the server — which never sees a
  // private key — cannot read the payloads. Peers without a key keep using
  // plaintext (backward compatible).
  final X25519 _x25519 = X25519();
  SimpleKeyPair? _e2ePair;
  Uint8List? _e2ePub;
  final Map<String, SecretKey> _peerKeys = {};

  /// In-flight E2E key derivations per peer (set by [setPeerE2E]). Encrypt and
  /// decrypt await any pending derivation so a frame that arrives right after
  /// the `hello` that started it is never dropped for lack of a key.
  final Map<String, Future<void>> _e2eDerivations = {};

  /// Generate this device's ephemeral keypair (once) and cache its public key.
  Future<void> ensureE2E() async {
    if (_e2ePair == null) {
      _e2ePair = await _x25519.newKeyPair();
      _e2ePub =
          Uint8List.fromList((await _e2ePair!.extractPublicKey()).bytes);
    }
  }

  /// Our X25519 public key, base64. Null until [ensureE2E] completes.
  String? get e2ePubB64 {
    final pub = _e2ePub;
    return pub == null ? null : base64Encode(pub);
  }

  /// Derive + cache the shared AES key for [peerId] from their public key.
  ///
  /// Records the derivation as in-flight so a frame that arrives before it
  /// finishes (e.g. the hello that started it was processed, then a file_meta
  /// + first chunk follow immediately) waits for the key instead of being
  /// dropped. The `hello` handler calls this fire-and-forget; [setPeerE2E]
  /// still returns the future for callers that want to await it.
  Future<void> setPeerE2E(String peerId, Uint8List peerPubBytes) {
    final future = _deriveKey(peerId, peerPubBytes);
    _e2eDerivations[peerId] = future;
    return future;
  }

  Future<void> _deriveKey(String peerId, Uint8List peerPubBytes) async {
    try {
      debugPrint('[e2e] deriving shared key for $peerId');
      await ensureE2E();
      final shared = await _x25519.sharedSecretKey(
        keyPair: _e2ePair!,
        remotePublicKey: SimplePublicKey(peerPubBytes, type: KeyPairType.x25519),
      );
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      _peerKeys[peerId] = await hkdf.deriveKey(
        secretKey: shared,
        nonce: utf8.encode('peerm-e2e-v1'),
      );
    } finally {
      _e2eDerivations.remove(peerId);
    }
  }

  /// Wait for an in-flight E2E key derivation for [peerId] to finish (if any)
  /// so the shared key is available before encrypting/decrypting. Failures are
  /// swallowed: the caller falls back to plaintext (sender) or drops the frame
  /// (receiver) exactly as it would with no key at all.
  Future<void> _awaitE2E(String peerId) async {
    final pending = _e2eDerivations[peerId];
    if (pending == null) return;
    try {
      await pending;
    } catch (_) {}
  }

  void removePeerKey(String peerId) {
    _peerKeys.remove(peerId);
    _e2eDerivations.remove(peerId);
  }

  bool hasPeerKey(String peerId) => _peerKeys.containsKey(peerId);

  Future<SecretKey?> _getKeyWithRetry(String peerId) async {
    await _awaitE2E(peerId);
    var key = _peerKeys[peerId];
    if (key != null) return key;

    // Grace buffer: if encrypted packet arrives just before hello finishes derivation
    final stop = DateTime.now().add(const Duration(milliseconds: 1500));
    while (key == null && DateTime.now().isBefore(stop)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _awaitE2E(peerId);
      key = _peerKeys[peerId];
    }
    return key;
  }

  /// AES-GCM encrypt [plaintext] for [peerId] → base64(nonce||ct||tag),
  /// or null if there's no shared key (caller should send plaintext).
  Future<String?> encryptTextFor(String peerId, String plaintext) async {
    await _awaitE2E(peerId);
    final key = _peerKeys[peerId];
    if (key == null) return null;
    final aes = AesGcm.with256bits();
    final nonce = aes.newNonce();
    final box =
        await aes.encrypt(utf8.encode(plaintext), secretKey: key, nonce: nonce);
    return base64Encode([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Decrypt base64(nonce||ct||tag) from [peerId]; null if no key / bad tag.
  Future<Uint8List?> decryptTextFor(String peerId, String b64) async {
    final key = await _getKeyWithRetry(peerId);
    debugPrint('[diag] decryptTextFor hasKey=${key != null}');
    if (key == null) return null;
    try {
      final raw = base64Decode(b64);
      if (raw.length < 28) return null;
      return await _aesGcmDecrypt(key, raw);
    } catch (_) {
      return null;
    }
  }

  /// AES-GCM encrypt [bytes] for [peerId] → nonce||ct||tag, or null if no key.
  Future<Uint8List?> encryptBinaryFor(String peerId, Uint8List bytes) async {
    await _awaitE2E(peerId);
    final key = _peerKeys[peerId];
    if (key == null) return null;
    final aes = AesGcm.with256bits();
    final nonce = aes.newNonce();
    final box = await aes.encrypt(bytes, secretKey: key, nonce: nonce);
    return Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Decrypt nonce||ct||tag from [peerId]; null if no key / bad tag.
  Future<Uint8List?> decryptBinaryFor(String peerId, Uint8List frame) async {
    final key = await _getKeyWithRetry(peerId);
    if (key == null) return null;
    try {
      if (frame.length < 28) return null;
      return await _aesGcmDecrypt(key, frame);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _aesGcmDecrypt(SecretKey key, Uint8List raw) async {
    final nonce = raw.sublist(0, 12);
    final ct = raw.sublist(12, raw.length - 16);
    final mac = raw.sublist(raw.length - 16);
    final aes = AesGcm.with256bits();
    final clear = await aes.decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
    );
    return Uint8List.fromList(clear);
  }

  Future<void> start() async {
    _manualStop = false;
    await _connect();
  }

  Future<void> restart() async {
    await stop();
    _attempt = 0;
    await start();
  }

  Future<void> stop() async {
    _manualStop = true;
    _generation++; // invalidate any in-flight _connect
    _connected = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    final ch = _channel;
    _channel = null;
    _resetRelayState();
    await ch?.sink.close();
  }

  Future<void> _connect() async {
    if (_manualStop || _disposed) return;
    final gen = ++_generation;
    try {
      final uri = Uri.parse(identity.serverUrl);
      _warnIfInsecure(uri);
      final channel = WebSocketChannel.connect(uri);
      // Don't let a dead/unreachable server stall startup or reconnect for the
      // OS TCP timeout (can be 30-120s). Fail fast so the UI never waits on
      // the connection; _handleDisconnect schedules a retry with backoff.
      await channel.ready.timeout(const Duration(seconds: 10));
      // A stop()/start() happened while we were connecting — don't resurrect.
      if (_manualStop || _disposed || gen != _generation) {
        try {
          await channel.sink.close();
        } catch (_) {}
        return;
      }
      _channel = channel;
      _connected = true;
      _attempt = 0;
      _lastServerActivity = DateTime.now();
      _startHeartbeat();
      debugPrint('[signaling] connected to ${identity.serverUrl}');
      _incoming.add({'type': '_local', 'event': 'connected'});
      // Register once the socket is open. If the server previously issued us
      // a device-auth secret, present it so the registration is authorized.
      // We also tell the server which devices we're already paired with (id +
      // name) — if this is a NEW host (after failover) it uses these to restore
      // the pairing instead of starting empty and unpairing us.
      final pairings = <Map<String, String>>[
        for (final entry in identity.pairedDeviceNames.entries)
          {'deviceId': entry.key, 'deviceName': entry.value},
      ];
      send({
        'type': 'register',
        'deviceId': identity.deviceId,
        'deviceName': identity.deviceName,
        'secret': identity.deviceSecret,
        'pairings': pairings,
      });
      channel.stream.listen(
        (raw) => _handleRaw(raw),
        onError: (Object e) {
          // Only the CURRENT connection may tear down the session. A stale
          // socket (e.g. the previous host's socket finally erroring after a
          // reconnect) must not null `_channel` and force another reconnect —
          // that makes the server 'replaced'-kick the active socket → flap.
          if (!identical(channel, _channel)) return;
          debugPrint(
              '[signaling] socket error: $e code=${channel.closeCode} reason=${channel.closeReason}');
          _handleDisconnect();
        },
        onDone: () {
          if (!identical(channel, _channel)) return;
          debugPrint(
              '[signaling] socket closed code=${channel.closeCode} reason=${channel.closeReason}');
          _handleDisconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[signaling] connect failed: $e');
      // A STALE connect (one superseded by a stop()/start() or takeover) must
      // not tear down the current, healthy connection. Only the current
      // generation may call _handleDisconnect.
      if (gen != _generation) return;
      _handleDisconnect();
    }
  }

  void _handleRaw(dynamic raw) {
    // Any traffic from the server means the link is alive.
    _lastServerActivity = DateTime.now();
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          debugPrint('[diag] raw type=${decoded['type']} from=${decoded['from']}');
          if (decoded['type'] == 'relay_ack') {
            // Backpressure signal: our in-flight binary frame was relayed, so
            // the next chunk may go out.
            _onRelayAck();
            return;
          }
          if (decoded['type'] == 'pong') {
            // Liveness reply — keeps the connection marked alive; not app-facing.
            return;
          }
          if (decoded['type'] == 'registered' && decoded['secret'] is String) {
            // Persist the device-auth secret the server issued (first contact).
            identity.setDeviceSecret(decoded['secret'] as String);
          }
          if (decoded['type'] == 'error' && decoded['message'] == 'unauthorized') {
            // The server rejected our deviceId+secret. In the host-election
            // model a device's stored secret was often issued by a PREVIOUS
            // host's server and is stale against the new host. Clear it and
            // reconnect: an empty secret makes the server re-bind a fresh one
            // (never locks out), so we recover on the next attempt. Still
            // surface it so the UI/log can react.
            debugPrint(
                '[signaling] register rejected: unauthorized - clearing stale secret and retrying');
            identity.clearDeviceSecret();
            _incoming.add({'type': '_local', 'event': 'unauthorized'});
            _handleDisconnect();
            return;
          }
          _incoming.add(decoded);
        }
      } catch (_) {}
    } else if (raw is List<int>) {
      // Raw binary frame (a relayed chunk body). The consumer pairs it with
      // the most recent {t:'bin'} relay marker to know which peer sent it.
      _incoming.add({
        'type': '_local',
        'event': 'binary',
        'bytes': raw is Uint8List ? raw : Uint8List.fromList(raw),
      });
    }
  }

  /// Warn (only) if we're about to send pairing codes / relayed music over
  /// plaintext `ws://` to a public host. Loopback and private LAN addresses
  /// (the phone-hotspot setup) are fine and keep working; anything else should
  /// use `wss://` in production so signaling + relayed files stay encrypted.
  void _warnIfInsecure(Uri uri) {
    if (uri.scheme != 'ws') return; // wss:// is encrypted
    final h = uri.host.toLowerCase();
    if (h == 'localhost' || h == '::1') return;
    final ip = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(h);
    if (ip != null) {
      final a = int.tryParse(ip[1]!) ?? -1;
      final b = int.tryParse(ip[2]!) ?? -1;
      if (a == 10 || a == 127) return; // private / loopback
      if (a == 192 && b == 168) return; // private
      if (a == 172 && b >= 16 && b <= 31) return; // private
      if (a == 169 && b == 254) return; // link-local
    }
    if (h.startsWith('fc') || h.startsWith('fd')) return; // IPv6 ULA
    debugPrint('[signaling] WARNING: connecting to ${uri.host} over unencrypted ws://. '
        'Pairing codes and relayed files will be readable on the network — use wss:// in production.');
  }

  void _handleDisconnect() {
    _connected = false;
    _channel = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _resetRelayState();
    _incoming.add({'type': '_local', 'event': 'disconnected'});
    if (_manualStop || _disposed) return;
    final attempt = _attempt > 5 ? 5 : _attempt;
    final delay = (2 * (1 << attempt)) * 1000;
    // A little jitter so several devices don't reconnect in lockstep.
    final jitter = math.Random().nextInt(1000);
    _attempt++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delay + jitter), _connect);
    debugPrint(
        '[signaling] disconnected; reconnecting in ${delay + jitter}ms');
  }

  void send(Map<String, dynamic> msg) {
    try {
      _channel?.sink.add(jsonEncode(msg));
    } catch (_) {}
  }

  void createPairing() => send({'type': 'create_pairing'});

  void pairWithCode(String code) =>
      send({'type': 'pair_with_code', 'code': code});

  void signalTo(String peerId, Map<String, dynamic> data) =>
      send({'type': 'signal', 'to': peerId, 'data': data});

  /// Relay a small control message (JSON text) to a paired peer. When a shared
  /// E2E key exists, the payload is AES-GCM encrypted (base64 nonce||ct||tag)
  /// so the relay server can't read it; otherwise it's sent as-is (old peers).
  Future<void> sendRelay(String peerId, Map<String, dynamic> data) async {
    await _awaitE2E(peerId);
    if (data['t'] == 'text' &&
        data['d'] is String &&
        _peerKeys.containsKey(peerId)) {
      final enc = await encryptTextFor(peerId, data['d'] as String);
      if (enc != null) {
        send({
          'type': 'relay',
          'to': peerId,
          'data': {'t': 'text', 'e': 1, 'd': enc},
        });
        return;
      }
    }
    send({'type': 'relay', 'to': peerId, 'data': data});
  }

  /// Relay a binary chunk to a paired peer.
  ///
  /// Sends a JSON marker (so the server knows which peer the following frame
  /// is for) followed by a raw binary frame, then waits for the server's
  /// `relay_ack` (which it only sends after relaying, and delays when the
  /// receiver is slow). This paces the sender to both the network and the
  /// receiving peer, keeping transfers memory-bounded. Returns once the chunk
  /// is acked or after a short safety timeout (a lost ack is healed by the
  /// reconnect + manifest re-sync, never by stalling forever).
  Future<void> sendRelayBinary(String peerId, Uint8List bytes) {
    // Serialize all binary sequences globally: exactly one marker+frame pair
    // is in flight at a time, so the server always pairs each frame with the
    // right marker and the next ack always belongs to our frame.
    final completer = Completer<void>();
    final previous = _relayLock;
    _relayLock = completer.future;

    return previous.then((_) async {
      try {
        final ch = _channel;
        if (ch == null) return;
        // E2E: encrypt the whole chunk envelope (nonce||ct||tag) and mark the
        // marker with e:1 when a shared key exists; no key → plaintext so old
        // peers keep working.
        await _awaitE2E(peerId);
        final encrypted = _peerKeys.containsKey(peerId);
        final payload = encrypted
            ? (await encryptBinaryFor(peerId, bytes)) ?? bytes
            : bytes;
        ch.sink.add(jsonEncode({
          'type': 'relay',
          'to': peerId,
          'data': {'t': 'bin', if (encrypted) 'e': 1},
        }));
        ch.sink.add(payload);

        final ack = Completer<void>();
        _pendingRelayAck = ack;
        // Safety timeout: if the ack is lost (e.g. server restarted mid-sync),
        // don't stall the channel forever — the resync heals it.
        _relayAckTimeout?.cancel();
        _relayAckTimeout = Timer(const Duration(seconds: 5), () {
          if (!ack.isCompleted) ack.complete();
        });
        try {
          await ack.future;
        } finally {
          _relayAckTimeout?.cancel();
          _relayAckTimeout = null;
          if (identical(_pendingRelayAck, ack)) _pendingRelayAck = null;
        }
      } finally {
        if (!completer.isCompleted) completer.complete();
      }
    }).catchError((Object e) {
      debugPrint('[signaling] sendRelayBinary error: $e');
    });
  }

  void _onRelayAck() {
    final ack = _pendingRelayAck;
    if (ack != null && !ack.isCompleted) ack.complete();
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) => _sendPing());
  }

  void _sendPing() {
    if (!_connected) return;
    if (DateTime.now().difference(_lastServerActivity) > _deadAfter) {
      // The server went silent (restarted / half-open link). Force a reconnect
      // instead of sitting in a fake "connected" state.
      debugPrint(
          '[signaling] no server activity for ${_deadAfter.inSeconds}s; '
          'forcing reconnect');
      _handleDisconnect();
      return;
    }
    send({'type': 'ping'});
  }

  void _resetRelayState() {
    _relayAckTimeout?.cancel();
    _relayAckTimeout = null;
    final ack = _pendingRelayAck;
    if (ack != null && !ack.isCompleted) ack.complete();
    _pendingRelayAck = null;
    _relayLock = Future<void>.value();
  }

  void unpair(String peerId) => send({'type': 'unpair', 'peerId': peerId});

  void getState() => send({'type': 'get_state'});

  /// One-shot "pairing check-in" with [url], independent of this instance's
  /// main connection. Registers reporting [pairings] (our own believed
  /// pairing list) and returns the peer map from an `unpaired` push if that
  /// server says this device's pairing to one of them is dead (tombstoned);
  /// returns null on success/no correction/any failure. Always closes the
  /// socket before returning — this never leaves a lingering connection.
  ///
  /// Needed because normal pairing reconciliation only runs when a device
  /// REGISTERS with a host. If two paired devices both end up independently
  /// hosting their own server (a "split brain" — e.g. after a failover where
  /// host-election never makes either defer to the other), neither's
  /// register-time reconciliation ever runs against the other, so a pairing
  /// broken on one side can appear to "stick forever" on the other. This
  /// lets a host proactively check in with such a peer without disturbing
  /// its own hosting role or its main connection.
  static Future<Map<String, dynamic>?> checkInWithHost({
    required String url,
    required String deviceId,
    required String deviceName,
    required List<Map<String, String>> pairings,
    Duration timeout = const Duration(seconds: 5),
    Duration graceAfterRegistered = const Duration(milliseconds: 400),
  }) async {
    WebSocketChannel? channel;
    StreamSubscription<dynamic>? sub;
    Timer? graceTimer;
    try {
      channel = WebSocketChannel.connect(Uri.parse(url));
      await channel.ready.timeout(timeout);
      final completer = Completer<Map<String, dynamic>?>();
      sub = channel.stream.listen((raw) {
        if (raw is! String || completer.isCompleted) return;
        Map<String, dynamic> msg;
        try {
          msg = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        if (msg['type'] == 'unpaired') {
          completer.complete(Map<String, dynamic>.from(msg['peer'] as Map));
        } else if (msg['type'] == 'registered') {
          // The server sends any correction ('unpaired') right after
          // 'registered', synchronously, in the same register handler — so a
          // short grace window is enough to know "no correction is coming"
          // without blocking the full [timeout] on every ordinary check-in.
          graceTimer ??= Timer(graceAfterRegistered, () {
            if (!completer.isCompleted) completer.complete(null);
          });
        }
      }, onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      }, onDone: () {
        if (!completer.isCompleted) completer.complete(null);
      });
      channel.sink.add(jsonEncode({
        'type': 'register',
        'deviceId': deviceId,
        'deviceName': deviceName,
        'secret': '',
        'pairings': pairings,
      }));
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      graceTimer?.cancel();
      await sub?.cancel();
      try {
        unawaited(channel?.sink.close());
      } catch (_) {}
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _pingTimer = null;
    _resetRelayState();
    _channel?.sink.close();
    _incoming.close();
  }
}
