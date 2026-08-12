import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:peerm_app/services/signaling_server.dart';
import 'package:peerm_app/services/signaling_service.dart';

/// Minimal WebSocket test client. Duplicated from signaling_server_test.dart
/// (which keeps its own copy private to that file) so this file stays
/// self-contained.
class _Client {
  _Client(this.ws) {
    _sub = ws.listen((data) => _messages.add(data), onError: (_) {});
  }
  final WebSocket ws;
  final List<dynamic> _messages = [];
  StreamSubscription<dynamic>? _sub;

  Future<Map<String, dynamic>> next(String type) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      for (var i = 0; i < _messages.length; i++) {
        final m = _messages[i];
        if (m is String) {
          try {
            final d = jsonDecode(m);
            if (d is Map && d['type'] == type) {
              _messages.removeAt(i);
              return d.cast<String, dynamic>();
            }
          } catch (_) {}
        }
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting for "$type" (have ${_messages.length} messages)');
  }

  void sendText(Map<String, dynamic> msg) => ws.add(jsonEncode(msg));

  Future<void> close() async {
    try {
      await _sub?.cancel();
      await ws.close();
    } catch (_) {}
  }
}

Future<_Client> _connect(int port) async {
  final ws = await WebSocket.connect('ws://127.0.0.1:$port');
  return _Client(ws);
}

void main() {
  test(
      'checkInWithHost surfaces a tombstoned pairing without disturbing the '
      "server's normal state", () async {
    final server = SignalingServer(port: 0, host: '127.0.0.1');
    await server.start();
    try {
      // Seed the exact split-brain precondition: A and B pair, then B
      // explicitly unpairs A while A is not connected (A never learns).
      final b = await _connect(server.boundPort);
      b.sendText({'type': 'register', 'deviceId': 'B', 'deviceName': 'Dev B'});
      await b.next('registered');

      final a1 = await _connect(server.boundPort);
      a1.sendText({'type': 'register', 'deviceId': 'A', 'deviceName': 'Dev A'});
      await a1.next('registered');

      a1.sendText({'type': 'create_pairing'});
      final code = (await a1.next('pairing_created'))['code'] as String;
      b.sendText({'type': 'pair_with_code', 'code': code});
      await b.next('paired');
      await a1.next('paired');

      b.sendText({'type': 'unpair', 'peerId': 'A'});
      await b.next('unpaired');
      await a1.close();

      // A comes back as its own independent host and never re-registers
      // with this server directly — instead it does exactly what
      // AppController._reconcileGhostPairings does: a one-shot check-in.
      final revoked = await SignalingService.checkInWithHost(
        url: 'ws://127.0.0.1:${server.boundPort}',
        deviceId: 'A',
        deviceName: 'Dev A',
        pairings: const [
          {'deviceId': 'B', 'deviceName': 'Dev B'},
        ],
      );

      expect(revoked, isNotNull,
          reason: 'the server must report the tombstoned pairing back');
      expect(revoked!['deviceId'], 'B');

      // A second check-in must be harmless (no crash, no resurrection) —
      // confirms it's safe to run on every 30s reconcile tick.
      final again = await SignalingService.checkInWithHost(
        url: 'ws://127.0.0.1:${server.boundPort}',
        deviceId: 'A',
        deviceName: 'Dev A',
        pairings: const [
          {'deviceId': 'B', 'deviceName': 'Dev B'},
        ],
      );
      expect(again, isNotNull);
      expect(again!['deviceId'], 'B');

      await b.close();
    } finally {
      await server.stop();
    }
  });

  test('checkInWithHost does not revoke a pairing that is genuinely still '
      'valid', () async {
    final server = SignalingServer(port: 0, host: '127.0.0.1');
    await server.start();
    try {
      final b = await _connect(server.boundPort);
      b.sendText({'type': 'register', 'deviceId': 'B', 'deviceName': 'Dev B'});
      await b.next('registered');
      final a = await _connect(server.boundPort);
      a.sendText({'type': 'register', 'deviceId': 'A', 'deviceName': 'Dev A'});
      await a.next('registered');
      a.sendText({'type': 'create_pairing'});
      final code = (await a.next('pairing_created'))['code'] as String;
      b.sendText({'type': 'pair_with_code', 'code': code});
      await b.next('paired');
      await a.next('paired');
      await a.close(); // A goes offline, but was never unpaired.

      final revoked = await SignalingService.checkInWithHost(
        url: 'ws://127.0.0.1:${server.boundPort}',
        deviceId: 'A',
        deviceName: 'Dev A',
        pairings: const [
          {'deviceId': 'B', 'deviceName': 'Dev B'},
        ],
      );
      expect(revoked, isNull,
          reason: 'a real, still-valid pairing must never be revoked');

      await b.close();
    } finally {
      await server.stop();
    }
  });

  test('checkInWithHost returns null against an unreachable server', () async {
    final revoked = await SignalingService.checkInWithHost(
      url: 'ws://127.0.0.1:1', // nothing listens here
      deviceId: 'A',
      deviceName: 'Dev A',
      pairings: const [],
      timeout: const Duration(seconds: 1),
    );
    expect(revoked, isNull);
  });
}
