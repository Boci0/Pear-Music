import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/relay_data_channel.dart';
import 'package:peerm_app/services/signaling_service.dart';

/// A [SignalingService] that records what the relay asks it to send, so the
/// channel's ordering and transport choices can be asserted without a server.
class _RecordingSignaling extends SignalingService {
  _RecordingSignaling(super.identity);

  final calls = <String>[];

  @override
  Future<void> sendRelay(String peerId, Map<String, dynamic> data) async {
    calls.add('relay:$peerId:${data['t']}');
  }

  @override
  Future<void> sendRelayBinary(String peerId, Uint8List bytes) async {
    calls.add('binary:$peerId:${bytes.length}');
  }
}

void main() {
  late IdentityService identity;
  late RelayDataChannel relay;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'peerm_device_id': 'device-A'});
    identity = IdentityService(await SharedPreferences.getInstance());
    final signaling = SignalingService(identity);
    relay = RelayDataChannel(peerId: 'device-B', signaling: signaling);
  });

  test('relay delivers text messages', () {
    final received = <RTCDataChannelMessage>[];
    relay.onMessage = received.add;

    relay.handleRelay({'t': 'text', 'd': '{"type":"hello"}'});

    expect(received.length, 1);
    expect(received.single.isBinary, isFalse);
    expect(received.single.text, '{"type":"hello"}');
  });

  test('relay delivers raw binary frames', () {
    final received = <RTCDataChannelMessage>[];
    relay.onMessage = received.add;

    final payload = Uint8List.fromList(
      List<int>.generate(70000, (i) => (i * 13) % 256),
    );
    relay.handleRelayBinary(payload);

    expect(received.length, 1);
    expect(received.single.isBinary, isTrue);
    expect(received.single.binary, payload);
  });

  test('relay ignores non-text inbound messages (binary markers)', () {
    final received = <RTCDataChannelMessage>[];
    relay.onMessage = received.add;

    relay.handleRelay({'t': 'bin'});

    expect(received, isEmpty);
  });

  test('relay send preserves order and uses raw binary for chunks', () async {
    final signaling = _RecordingSignaling(identity);
    final channel = RelayDataChannel(peerId: 'device-B', signaling: signaling);

    await channel.send(RTCDataChannelMessage('{"type":"manifest"}'));
    await channel.send(
      RTCDataChannelMessage.fromBinary(Uint8List.fromList([1, 2, 3])),
    );
    await channel.send(RTCDataChannelMessage('{"type":"file_done","id":"x"}'));

    expect(signaling.calls, [
      'relay:device-B:text',
      'binary:device-B:3',
      'relay:device-B:text',
    ]);
  });

  test('relay send works with no active server connection', () async {
    // sendRelay/sendRelayBinary must be safe no-ops when the socket is closed.
    await relay.send(RTCDataChannelMessage('{"type":"manifest"}'));
    await relay.send(
      RTCDataChannelMessage.fromBinary(Uint8List.fromList([9, 8, 7])),
    );
  });

  test('relay E2E: encrypted text and binary are decrypted on receipt', () async {
    // Two signaling services derive the SAME shared key from each other's
    // public key, exactly like two real devices would after the hello handshake.
    final sigA = SignalingService(identity);
    final sigB = SignalingService(identity);
    await sigA.ensureE2E();
    await sigB.ensureE2E();
    expect(sigA.e2ePubB64, isNotNull);
    expect(sigB.e2ePubB64, isNotNull);
    final pubA = base64Decode(sigA.e2ePubB64!);
    final pubB = base64Decode(sigB.e2ePubB64!);
    await sigA.setPeerE2E('device-B', pubB);
    await sigB.setPeerE2E('device-A', pubA);

    final relayB = RelayDataChannel(peerId: 'device-A', signaling: sigB);
    final received = <RTCDataChannelMessage>[];
    relayB.onMessage = received.add;

    // A encrypts a text message; B's relay decrypts and delivers it.
    final encText = await sigA.encryptTextFor('device-B', '{"type":"hello"}');
    expect(encText, isNotNull);
    await relayB.handleRelay({'t': 'text', 'e': 1, 'd': encText});
    expect(received.length, 1);
    expect(received.single.isBinary, isFalse);
    expect(received.single.text, '{"type":"hello"}');

    // A encrypts a binary chunk; B's relay decrypts and delivers it intact.
    final payload = Uint8List.fromList(
      List<int>.generate(70000, (i) => (i * 13) % 256),
    );
    final encBin = await sigA.encryptBinaryFor('device-B', payload);
    expect(encBin, isNotNull);
    await relayB.handleRelayBinary(encBin!, encrypted: true);
    expect(received.length, 2);
    expect(received.last.isBinary, isTrue);
    expect(received.last.binary, payload);

    // A tampered / wrong-key frame is dropped, never surfaced.
    final bad = Uint8List.fromList(encBin);
    bad[20] = bad[20] ^ 0xFF;
    await relayB.handleRelayBinary(bad, encrypted: true);
    expect(received.length, 2);
  });

  test('relay plaintext path still works when there is no shared key',
      () async {
    final received = <RTCDataChannelMessage>[];
    relay.onMessage = received.add;

    await relay.handleRelay({'t': 'text', 'd': '{"type":"hello"}'});
    await relay.handleRelayBinary(
      Uint8List.fromList([1, 2, 3]),
      encrypted: false,
    );

    expect(received.length, 2);
    expect(received[0].text, '{"type":"hello"}');
    expect(received[1].binary, [1, 2, 3]);
  });

  test('E2E fingerprints match on both sides and detect a wrong key', () async {
    final sigA = SignalingService(identity);
    final sigB = SignalingService(identity);
    await sigA.ensureE2E();
    await sigB.ensureE2E();
    final pubA = base64Decode(sigA.e2ePubB64!);
    final pubB = base64Decode(sigB.e2ePubB64!);
    await sigA.setPeerE2E('device-B', pubB);
    await sigB.setPeerE2E('device-A', pubA);

    // Both sides compute the SAME code from the two public keys.
    final fpA = sigA.e2eFingerprintFor('device-B');
    final fpB = sigB.e2eFingerprintFor('device-A');
    expect(fpA, isNotNull);
    expect(fpA, fpB);
    expect(RegExp(r'^[A-Z0-9]{5}-[A-Z0-9]{5}$').hasMatch(fpA!), isTrue);

    // A different key (a man-in-the-middle) yields a different code.
    final sigM = SignalingService(identity);
    await sigM.ensureE2E();
    final pubM = base64Decode(sigM.e2ePubB64!);
    await sigA.setPeerE2E('device-B', pubM);
    expect(sigA.e2eFingerprintFor('device-B'), isNot(fpA));
  });
}
