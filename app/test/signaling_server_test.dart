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
  });
}
