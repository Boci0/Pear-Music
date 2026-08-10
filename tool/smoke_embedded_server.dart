import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Connects to a running Pear Music app's embedded signaling server and
// exercises register + create_pairing, printing the results.
Future<void> main() async {
  final ws = await WebSocket.connect('ws://localhost:8080');
  final messages = <String>[];
  final sub = ws.listen((data) {
    if (data is String) messages.add(data);
  });

  Future<Map<String, dynamic>> waitFor(String type) async {
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (DateTime.now().isBefore(deadline)) {
      for (var i = 0; i < messages.length; i++) {
        try {
          final d = jsonDecode(messages[i]);
          if (d is Map<String, dynamic> && d['type'] == type) {
            messages.removeAt(i);
            return d;
          }
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('timeout waiting for $type; got ${messages.toList()}');
  }

  ws.add(jsonEncode({
    'type': 'register',
    'deviceId': 'smoke-test-device',
    'deviceName': 'Smoke Test',
  }));
  final reg = await waitFor('registered');
  print('registered: deviceId=${reg['deviceId']} secret=${reg['secret']}');

  ws.add(jsonEncode({'type': 'create_pairing'}));
  final pairing = await waitFor('pairing_created');
  print('pairing_created: code=${pairing['code']} expiresIn=${pairing['expiresIn']}');

  ws.add(jsonEncode({'type': 'get_state'}));
  final state = await waitFor('state');
  print('state: deviceId=${state['deviceId']} pairings=${state['pairings']}');

  await sub.cancel();
  await ws.close();
  print('SMOKE TEST OK');
  exit(0);
}
