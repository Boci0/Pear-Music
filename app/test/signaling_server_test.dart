import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:peerm_app/services/signaling_server.dart';

/// A minimal WebSocket client that records every message and offers
/// wait-for-a-type helpers. Messages arrive as String (text) or
/// `List<int>`/`Uint8List` (binary).
class _Client {
  _Client(this.ws);
  final WebSocket ws;
  final List<dynamic> messages = [];
  StreamSubscription<dynamic>? _sub;

  void listen() {
    _sub = ws.listen(
      (data) => messages.add(data),
      onError: (_) {},
    );
  }

  Future<dynamic> _waitFor(bool Function(dynamic) match) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      for (var i = 0; i < messages.length; i++) {
        if (match(messages[i])) {
          return messages.removeAt(i);
        }
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting for a matching message (have ${messages.length})');
  }

  Future<Map<String, dynamic>> nextJson(String type) async {
    final raw = await _waitFor((m) {
      if (m is! String) return false;
      try {
        final d = jsonDecode(m);
        return d is Map<String, dynamic> && d['type'] == type;
      } catch (_) {
        return false;
      }
    });
    return (jsonDecode(raw as String) as Map).cast<String, dynamic>();
  }

  Future<Uint8List> nextBinary() async {
    final raw = await _waitFor((m) => m is List<int>);
    return raw is Uint8List ? raw : Uint8List.fromList(raw as List<int>);
  }

  void sendText(Map<String, dynamic> msg) => ws.add(jsonEncode(msg));
  void sendBinary(List<int> bytes) => ws.add(bytes);

  Future<void> close() async {
    try {
      await _sub?.cancel();
      await ws.close();
    } catch (_) {}
  }
}

void main() {
  Future<_Client> connect(int port) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port');
    final c = _Client(ws);
    c.listen();
    return c;
  }

  group('SignalingServer (embedded Dart port)', () {
    late SignalingServer server;
    late int port;

    setUp(() async {
      server = SignalingServer(port: 0, host: '127.0.0.1');
      await server.start();
      port = server.boundPort;
      expect(server.isRunning, isTrue);
    });

    tearDown(() async {
      await server.stop();
      expect(server.isRunning, isFalse);
    });

    test('health endpoint reports ok', () async {
      final client = HttpClient();
      final req = await client.get('127.0.0.1', port, '/health');
      final res = await req.close();
      expect(res.statusCode, 200);
      final body = await res.transform(utf8.decoder).join();
      expect(body, contains('"ok":true'));
      client.close();
    });

    test('discover endpoint returns peerm_hello (LAN discovery)', () async {
      final client = HttpClient();
      final req = await client.get('127.0.0.1', port, '/discover');
      final res = await req.close();
      expect(res.statusCode, 200);
      final body = await res.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      expect(data['type'], 'peerm_hello');
      expect(data['url'], startsWith('ws://'));
      expect(data['name'], isNotEmpty);
      client.close();
    });

    test('register -> create_pairing -> pair_with_code -> relay text -> relay binary -> unpair',
        () async {
      final a = await connect(port);
      final b = await connect(port);

      // Register both.
      a.sendText({'type': 'register', 'deviceId': 'A', 'deviceName': 'Dev A'});
      final regA = await a.nextJson('registered');
      expect(regA['deviceId'], 'A');
      expect(regA['secret'], isNotEmpty);

      b.sendText({'type': 'register', 'deviceId': 'B', 'deviceName': 'Dev B'});
      await b.nextJson('registered');

      // A creates a pairing code; B pairs with it.
      a.sendText({'type': 'create_pairing'});
      final created = await a.nextJson('pairing_created');
      final code = created['code'] as String;
      expect(code.length, 6);

      b.sendText({'type': 'pair_with_code', 'code': code});
      final bPaired = await b.nextJson('paired');
      expect((bPaired['peer'] as Map)['deviceId'], 'A');
      final aPaired = await a.nextJson('paired');
      expect((aPaired['peer'] as Map)['deviceId'], 'B');

      // Relay text A -> B.
      a.sendText({'type': 'relay', 'to': 'B', 'data': {'t': 'text', 'd': 'hello'}});
      final relayed = await b.nextJson('relay');
      expect(relayed['from'], 'A');
      expect((relayed['data'] as Map)['d'], 'hello');

      // Relay binary A -> B (marker + raw frame), sender gets relay_ack.
      a.sendText({'type': 'relay', 'to': 'B', 'data': {'t': 'bin'}});
      a.sendBinary([1, 2, 3, 4, 5]);
      final marker = await b.nextJson('relay');
      expect((marker['data'] as Map)['t'], 'bin');
      expect(marker['from'], 'A');
      final bin = await b.nextBinary();
      expect(bin, [1, 2, 3, 4, 5]);
      await a.nextJson('relay_ack');

      // Regression: the binary marker must PRESERVE the `e:1` encryption flag
      // so the receiver knows to decrypt the frame. It was dropped before,
      // which broke sync once E2E encryption actually turned on.
      a.sendText({'type': 'relay', 'to': 'B', 'data': {'t': 'bin', 'e': 1}});
      a.sendBinary([9, 9, 9]);
      final encMarker = await b.nextJson('relay');
      expect((encMarker['data'] as Map)['e'], 1,
          reason: 'encryption flag must be forwarded to the receiver');
      final encBin = await b.nextBinary();
      expect(encBin, [9, 9, 9]);
      await a.nextJson('relay_ack');

      // A relay to a NON-paired device is dropped (no message to C).
      final c = await connect(port);
      c.sendText({'type': 'register', 'deviceId': 'C', 'deviceName': 'Dev C'});
      await c.nextJson('registered');
      a.sendText({'type': 'relay', 'to': 'C', 'data': {'t': 'text', 'd': 'nope'}});
      final received = c.messages.whereType<String>().length;
      await Future.delayed(const Duration(milliseconds: 300));
      expect(c.messages.whereType<String>().length, received);

      // Unpair B from A's side.
      b.sendText({'type': 'unpair', 'peerId': 'A'});
      await b.nextJson('unpaired');
      await a.nextJson('unpaired');

      await a.close();
      await b.close();
      await c.close();
    });

    test('an oversized text frame is rejected instead of being processed',
        () async {
      final a = await connect(port);
      // A single text frame well over maxTextPayload (4 MB). It must be
      // rejected (socket closed) before it's ever JSON-decoded, not
      // silently accepted like every text frame used to be.
      final huge = 'x' * (SignalingServer.maxTextPayload + 1024);
      a.ws.add(huge);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (a.ws.readyState == WebSocket.open &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(a.ws.readyState, isNot(WebSocket.open),
          reason: 'an oversized text frame must close the connection');
      await a.close();
    });

    test('pairing with a wrong code fails with an error', () async {
      final a = await connect(port);
      a.sendText({'type': 'register', 'deviceId': 'A', 'deviceName': 'Dev A'});
      await a.nextJson('registered');
      a.sendText({'type': 'pair_with_code', 'code': 'ZZZZZZ'});
      final err = await a.nextJson('error');
      expect(err['message'], contains('Invalid or expired'));
      await a.close();
    });

    test('register restores pairings on a fresh host (host failover)', () async {
      final a = await connect(port);
      final b = await connect(port);
      // A claims it is already paired with B (id + name) — as a client would
      // after the host fails over to this device.
      a.sendText({
        'type': 'register',
        'deviceId': 'A',
        'deviceName': 'Dev A',
        'pairings': [
          {'deviceId': 'B', 'deviceName': 'Dev B'},
        ],
      });
      await a.nextJson('registered');
      // The initial state sent right after register can't include B yet
      // (B hasn't registered) — drain it so we query the latest below.
      await a.nextJson('state');
      b.sendText({'type': 'register', 'deviceId': 'B', 'deviceName': 'Dev B'});
      await b.nextJson('registered');

      // The server should now consider A paired with B (restored by A, with
      // its name), so get_state reports B — the pairing survived the host
      // change and the offline peer stays visible.
      a.sendText({'type': 'get_state'});
      final state = await a.nextJson('state');
      final pairings = state['pairings'] as List;
      final bPeer = pairings
          .whereType<Map>()
          .where((p) => p['deviceId'] == 'B')
          .toList();
      expect(bPeer, isNotEmpty,
          reason: 'restored pairing should be reported in state');
      expect(bPeer.first['deviceName'], 'Dev B',
          reason: 'restored pairing should keep the peer name');
      await a.close();
      await b.close();
    });

    test('pairings survive a server restart via the state file', () async {
      final dir = await Directory.systemTemp.createTemp('peerm-server-restart');
      final stateFile = File('${dir.path}/state.json');

      final s1 = SignalingServer(port: 0, host: '127.0.0.1', stateFile: stateFile);
      await s1.start();
      final a = await connect(s1.boundPort);
      final b = await connect(s1.boundPort);
      a.sendText({'type': 'register', 'deviceId': 'A', 'deviceName': 'Dev A'});
      await a.nextJson('registered');
      b.sendText({'type': 'register', 'deviceId': 'B', 'deviceName': 'Dev B'});
      await b.nextJson('registered');
      a.sendText({'type': 'create_pairing'});
      final created = await a.nextJson('pairing_created');
      b.sendText({'type': 'pair_with_code', 'code': created['code'] as String});
      await b.nextJson('paired');
      await a.nextJson('paired');
      await a.close();
      await b.close();
      await s1.stop();

      // Restart on a fresh port with the same state file.
      final s2 = SignalingServer(port: 0, host: '127.0.0.1', stateFile: stateFile);
      await s2.start();
      final a2 = await connect(s2.boundPort);
      a2.sendText({'type': 'register', 'deviceId': 'A', 'deviceName': 'Dev A'});
      await a2.nextJson('registered');
      a2.sendText({'type': 'get_state'});
      final state = await a2.nextJson('state');
      final pairings = state['pairings'] as List;
      expect(
        pairings.any((p) => (p as Map)['deviceId'] == 'B'),
        isTrue,
        reason: 'persisted pairing to offline B should survive the restart',
      );
      await a2.close();
      await s2.stop();
      await dir.delete(recursive: true);
    });

    test(
        "the host's own device can always register (no self-lockout after failover)",
        () async {
      final s = SignalingServer(
          port: 0, host: '127.0.0.1', advertiseDeviceId: 'HOST');
      await s.start();
      try {
        // A peer registers with its own secret and is accepted.
        final peer = await connect(s.boundPort);
        peer.sendText({
          'type': 'register',
          'deviceId': 'PEER',
          'deviceName': 'Peer',
          'secret': 'S1',
        });
        await peer.nextJson('registered');

        // The same peer re-registering with a WRONG secret is still rejected
        // (normal auth still applies to non-own devices).
        final impostor = await connect(s.boundPort);
        impostor.sendText({
          'type': 'register',
          'deviceId': 'PEER',
          'deviceName': 'Peer',
          'secret': 'WRONG',
        });
        final err = await impostor.nextJson('error');
        expect(err['message'], 'unauthorized');

        // The server's OWN device registering with a stale (wrong) secret is
        // ACCEPTED and re-bound — the host can never lock itself out.
        final host = await connect(s.boundPort);
        host.sendText({
          'type': 'register',
          'deviceId': 'HOST',
          'deviceName': 'Host',
          'secret': 'STALE',
        });
        final reg = await host.nextJson('registered');
        expect(reg['secret'], 'STALE',
            reason: "own device's secret is adopted, not rejected");

        await host.close();
        await peer.close();
        await impostor.close();
      } finally {
        await s.stop();
      }
    });

    test(
        'a spoofed X-Forwarded-For is ignored by default (own-device bypass '
        'still keys off the REAL loopback address)', () async {
      // trustProxyHeaders defaults to false — a client-supplied header must
      // not change what IP the server thinks this connection is from.
      final s = SignalingServer(
          port: 0, host: '127.0.0.1', advertiseDeviceId: 'HOST');
      await s.start();
      try {
        final ws = await WebSocket.connect(
          'ws://127.0.0.1:${s.boundPort}',
          headers: {'X-Forwarded-For': '203.0.113.5'},
        );
        final c = _Client(ws)..listen();
        // Claims to be the host's own device with a stale/wrong secret. This
        // must still be ACCEPTED: the real TCP peer is loopback regardless
        // of the forged header, so the own-device bypass still applies.
        c.sendText({
          'type': 'register',
          'deviceId': 'HOST',
          'deviceName': 'Host',
          'secret': 'STALE',
        });
        final reg = await c.nextJson('registered');
        expect(reg['secret'], 'STALE');
        await c.close();
      } finally {
        await s.stop();
      }
    });

    test(
        'a non-loopback address (only reachable by opting into '
        'trustProxyHeaders) cannot bypass the own-device secret check',
        () async {
      final s = SignalingServer(
        port: 0,
        host: '127.0.0.1',
        advertiseDeviceId: 'HOST',
        trustProxyHeaders: true,
      );
      await s.start();
      try {
        // Establish the host's real secret via a normal (loopback, no
        // forwarded-for) connection.
        final host = await connect(s.boundPort);
        host.sendText({
          'type': 'register',
          'deviceId': 'HOST',
          'deviceName': 'Host',
          'secret': 'REAL',
        });
        await host.nextJson('registered');
        await host.close();

        // An attacker on the LAN learns 'HOST' from discovery (it's public)
        // and connects claiming a non-loopback address (only possible here
        // because this server opted into trustProxyHeaders) with the WRONG
        // secret. Since the claimed address isn't loopback, the own-device
        // bypass must NOT apply — normal secret auth kicks in and rejects it.
        final attacker = await WebSocket.connect(
          'ws://127.0.0.1:${s.boundPort}',
          headers: {'X-Forwarded-For': '203.0.113.5'},
        );
        final c = _Client(attacker)..listen();
        c.sendText({
          'type': 'register',
          'deviceId': 'HOST',
          'deviceName': 'Host',
          'secret': 'WRONG',
        });
        final err = await c.nextJson('error');
        expect(err['message'], 'unauthorized');
        await c.close();
      } finally {
        await s.stop();
      }
    });

    test(
        'register prunes an offline pairing the client no longer reports '
        '(ghost cleanup)', () async {
      final a = await connect(port); // the PC
      final ghost = await connect(port); // the old phone (will never return)

      a.sendText({'type': 'register', 'deviceId': 'PC', 'deviceName': 'PC'});
      await a.nextJson('registered');
      ghost.sendText(
          {'type': 'register', 'deviceId': 'GHOST', 'deviceName': 'Phone'});
      await ghost.nextJson('registered');

      // Pair GHOST with PC.
      a.sendText({'type': 'create_pairing'});
      final created = await a.nextJson('pairing_created');
      ghost.sendText(
          {'type': 'pair_with_code', 'code': created['code'] as String});
      await ghost.nextJson('paired');
      await a.nextJson('paired');

      // The ghost "dies" (its identity was reset): it disconnects and never
      // returns, but its persisted pairing to PC lingers.
      await ghost.close();

      // PC reconnects and reports ONLY its live pairing (the new phone); the
      // ghost is gone from its list. The server must reconcile: the ghost
      // (offline and unreported) is pruned from the persisted pairing so it can
      // never resurrect via another host's state file.
      final a2 = await connect(port);
      a2.sendText({
        'type': 'register',
        'deviceId': 'PC',
        'deviceName': 'PC',
        'pairings': [
          {'deviceId': 'PHONE', 'deviceName': 'My Phone'},
        ],
      });
      await a2.nextJson('registered');
      await a2.nextJson('state'); // drain the state sent right after register
      a2.sendText({'type': 'get_state'});
      final state = await a2.nextJson('state');
      final ids = (state['pairings'] as List)
          .whereType<Map>()
          .map((p) => p['deviceId'])
          .toList();
      expect(ids, contains('PHONE'),
          reason: 'the live reported pairing must be kept');
      expect(ids, isNot(contains('GHOST')),
          reason: 'an offline pairing the client no longer reports is a ghost '
              'and must be pruned so it cannot resurrect');
      await a2.close();
    });

    test('an offline peer not seen within the grace is hidden from state',
        () async {
      final dir = await Directory.systemTemp.createTemp('peerm-ghost-grace');
      final stateFile = File('${dir.path}/state.json');
      stateFile.writeAsStringSync(jsonEncode({
        'pairings': [
          ['PC', 'GHOST'],
        ],
        'names': {'PC': 'PC', 'GHOST': 'Ghost'},
        'secrets': <String, String>{},
        'lastSeen': {
          'PC': DateTime.now().toIso8601String(),
          // GHOST last connected 10 days ago — beyond the offline-report grace.
          'GHOST':
              DateTime.now().subtract(const Duration(days: 10)).toIso8601String(),
        },
      }));

      final s = SignalingServer(port: 0, host: '127.0.0.1', stateFile: stateFile);
      await s.start();
      try {
        final pc = await connect(s.boundPort);
        // Even though the client STILL reports the ghost, the server hides it
        // (its lastSeen is beyond the grace) so the client drops it from its
        // list and stops re-reporting it — the ghost cleans itself up.
        pc.sendText({
          'type': 'register',
          'deviceId': 'PC',
          'deviceName': 'PC',
          'pairings': [
            {'deviceId': 'GHOST', 'deviceName': 'Ghost'},
          ],
        });
        await pc.nextJson('registered');
        final state = await pc.nextJson('state');
        final ids = (state['pairings'] as List)
            .whereType<Map>()
            .map((p) => p['deviceId'])
            .toList();
        expect(ids, isNot(contains('GHOST')),
            reason: 'a long-gone offline peer must be hidden from state');
        await pc.close();
      } finally {
        await s.stop();
        await dir.delete(recursive: true);
      }
    });

    test('direct HTTP pairing and unpairing', () async {
      String? pairedId;
      String? pairedName;
      String? unpairedId;

      final s = SignalingServer(
        port: 0,
        host: '127.0.0.1',
        advertiseDeviceId: 'HOST-DEVICE',
        advertiseName: 'Host Machine',
        onPeerPaired: (id, name) {
          pairedId = id;
          pairedName = name;
        },
        onPeerUnpaired: (id) {
          unpairedId = id;
        },
      );
      await s.start();
      try {
        final code = s.createPairingCode();
        final client = HttpClient();

        // 1. Invalid code -> 400
        var req = await client.postUrl(Uri.parse('http://127.0.0.1:${s.boundPort}/api/pair'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({'code': 'WRONGG', 'deviceId': 'PEER-1', 'deviceName': 'Peer Phone'}));
        var resp = await req.close();
        expect(resp.statusCode, HttpStatus.badRequest);
        await resp.drain();

        // 2. Valid code -> 200 OK + mutual pair
        req = await client.postUrl(Uri.parse('http://127.0.0.1:${s.boundPort}/api/pair'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({'code': code, 'deviceId': 'PEER-1', 'deviceName': 'Peer Phone'}));
        resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);
        final body = await utf8.decodeStream(resp);
        final data = jsonDecode(body) as Map<String, dynamic>;
        expect(data['ok'], isTrue);
        expect(data['deviceId'], 'HOST-DEVICE');
        expect(data['deviceName'], 'Host Machine');
        expect(pairedId, 'PEER-1');
        expect(pairedName, 'Peer Phone');

        // 3. Direct unpair
        req = await client.postUrl(Uri.parse('http://127.0.0.1:${s.boundPort}/api/unpair'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({'deviceId': 'PEER-1'}));
        resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);
        expect(unpairedId, 'PEER-1');

        client.close();
      } finally {
        await s.stop();
      }
    });

    test('direct HTTP manifest and audio file streaming', () async {
      final tmpDir = await Directory.systemTemp.createTemp('pear_test_stream_');
      final dummyAudio = File('${tmpDir.path}/song1.mp3');
      final sampleBytes = List<int>.generate(256 * 1024, (i) => i % 256);
      await dummyAudio.writeAsBytes(sampleBytes);

      final s = SignalingServer(
        port: 0,
        host: '127.0.0.1',
        manifestProvider: () => {
          'songs': [
            {'id': 'song1', 'title': 'Test Song', 'size': sampleBytes.length}
          ],
          'playlists': [],
        },
        songFileProvider: (id) => id == 'song1' ? dummyAudio : null,
      );
      await s.start();
      try {
        final client = HttpClient();

        // 1. GET /api/sync/manifest
        var req = await client.getUrl(Uri.parse('http://127.0.0.1:${s.boundPort}/api/sync/manifest'));
        var resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);
        final manifest = jsonDecode(await utf8.decodeStream(resp)) as Map<String, dynamic>;
        expect(manifest['songs'], hasLength(1));
        expect(manifest['songs'][0]['id'], 'song1');

        // 2. GET /api/songs/song1 (Full stream)
        req = await client.getUrl(Uri.parse('http://127.0.0.1:${s.boundPort}/api/songs/song1'));
        resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);
        expect(resp.contentLength, sampleBytes.length);
        final downloadedBytes = await resp.expand((chunk) => chunk).toList();
        expect(downloadedBytes, equals(sampleBytes));

        // 3. GET /api/songs/song1 with Range header
        req = await client.getUrl(Uri.parse('http://127.0.0.1:${s.boundPort}/api/songs/song1'));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=1000-1999');
        resp = await req.close();
        expect(resp.statusCode, HttpStatus.partialContent);
        final partialBytes = await resp.expand((chunk) => chunk).toList();
        expect(partialBytes, equals(sampleBytes.sublist(1000)));

        client.close();
      } finally {
        await s.stop();
        await tmpDir.delete(recursive: true);
      }
    });
  });
}
