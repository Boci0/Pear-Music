import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

  test(
      'a fresh SignalingService generates its E2E key automatically '
      '(no manual ensureE2E needed)', () async {
    // Regression: the X25519 keypair used to only be generated inside
    // setPeerE2E, which never fired because no `hello` carried a key, so
    // relay encryption silently stayed off in real use (only tests called
    // ensureE2E explicitly). The constructor now kicks off key generation, so
    // a new instance's key becomes available on its own.
    final sig = SignalingService(identity);
    var pub = sig.e2ePubB64;
    for (var i = 0; i < 50 && pub == null; i++) {
      await Future.delayed(const Duration(milliseconds: 20));
      pub = sig.e2ePubB64;
    }
    expect(pub, isNotNull,
        reason: 'constructor should auto-generate the X25519 public key');
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

  test(
      'encrypt/decrypt await an in-flight E2E key derivation '
      '(a frame right after hello is never dropped)', () async {
    // Two distinct identities, like two real devices.
    SharedPreferences.setMockInitialValues({'peerm_device_id': 'device-A'});
    final idA = IdentityService(await SharedPreferences.getInstance());
    SharedPreferences.setMockInitialValues({'peerm_device_id': 'device-B'});
    final idB = IdentityService(await SharedPreferences.getInstance());
    final sigA = SignalingService(idA);
    final sigB = SignalingService(idB);
    await sigA.ensureE2E();
    await sigB.ensureE2E();
    final pubA = base64Decode(sigA.e2ePubB64!);
    final pubB = base64Decode(sigB.e2ePubB64!);

    // B starts deriving its key from A's public key FIRE-AND-FORGET, exactly
    // how the sync hello handler calls setPeerE2E (unawaited).
    unawaited(sigB.setPeerE2E('device-A', pubA));

    // A awaits its own derivation, then encrypts.
    await sigA.setPeerE2E('device-B', pubB);
    final payload = Uint8List.fromList(
      List<int>.generate(70000, (i) => (i * 17) % 251),
    );
    final enc = await sigA.encryptBinaryFor('device-B', payload);
    expect(enc, isNotNull);

    // B decrypts WITHOUT awaiting the derivation it started. The decrypt
    // helper must wait for the in-flight key internally, otherwise the frame
    // is dropped (the "size mismatch got 0" failure).
    final dec = await sigB.decryptBinaryFor('device-A', enc!);
    expect(dec, payload);
  });

  test('consecutive decrypt failures trip plaintext fallback, a good '
      'decrypt clears it', () async {
    // Two distinct identities, like two real devices.
    SharedPreferences.setMockInitialValues({'peerm_device_id': 'device-A'});
    final idA = IdentityService(await SharedPreferences.getInstance());
    SharedPreferences.setMockInitialValues({'peerm_device_id': 'device-B'});
    final idB = IdentityService(await SharedPreferences.getInstance());
    final sigA = SignalingService(idA);
    final sigB = SignalingService(idB);
    await sigA.ensureE2E();
    await sigB.ensureE2E();
    final pubB = base64Decode(sigB.e2ePubB64!);
    await sigA.setPeerE2E('device-B', pubB);

    expect(sigA.isPlaintextPeer('device-B'), isFalse);
    // A valid ciphertext captured BEFORE any failures; later it proves a
    // decrypt success re-enables E2E (while in fallback we refuse to encrypt).
    final validEnc = await sigA.encryptTextFor('device-B', 'still-here');
    expect(validEnc, isNotNull);
    // Feed the decrypt helper ciphertext that fails trace auth (all-zero
    // nonce||ct||tag of valid length): each must NOT wipe the key, and the
    // 3rd consecutive failure must trip fallback.
    var k = 0;
    while (k < 3) {
      final dec = await sigA.decryptTextFor(
        'device-B',
        base64Encode(Uint8List(40)),
      );
      expect(dec, isNull);
      k++;
    }
    expect(sigA.isPlaintextPeer('device-B'), isTrue,
        reason: '3 consecutive decrypt failures trip plaintext fallback');
    // While in fallback we no longer encrypt (returns null); the key was NOT
    // wiped by the failures.
    expect(await sigA.encryptTextFor('device-B', 'x'), isNull,
        reason: 'fallback forces plaintext so sync never stalls');

    // A later SUCCESSFUL decrypt (a working key turning E2E back on) clears
    // fallback immediately.
    final ok = await sigA.decryptTextFor('device-B', validEnc!);
    expect(utf8.decode(ok!), 'still-here');
    expect(sigA.isPlaintextPeer('device-B'), isFalse,
        reason: 'a decrypt success re-enables E2E');
  });

  test('re-pairing after key removal awaits derivation and decrypts correctly',
      () async {
    SharedPreferences.setMockInitialValues({'peerm_device_id': 'device-A'});
    final idA = IdentityService(await SharedPreferences.getInstance());
    SharedPreferences.setMockInitialValues({'peerm_device_id': 'device-B'});
    final idB = IdentityService(await SharedPreferences.getInstance());
    final sigA = SignalingService(idA);
    final sigB = SignalingService(idB);
    await sigA.ensureE2E();
    await sigB.ensureE2E();
    final pubA = base64Decode(sigA.e2ePubB64!);
    final pubB = base64Decode(sigB.e2ePubB64!);

    // Initial pairing
    await sigA.setPeerE2E('device-B', pubB);
    await sigB.setPeerE2E('device-A', pubA);

    // Unpair (keys removed)
    sigA.removePeerKey('device-B');
    sigB.removePeerKey('device-A');

    // Re-pair: derivations initiated unawaited (fire-and-forget)
    unawaited(sigA.setPeerE2E('device-B', pubB));
    unawaited(sigB.setPeerE2E('device-A', pubA));

    final payload = Uint8List.fromList([42, 43, 44, 45]);
    // Immediate encryption while derivation is still in-flight
    final enc = await sigA.encryptBinaryFor('device-B', payload);
    expect(enc, isNotNull);

    // Immediate decryption on other side
    final dec = await sigB.decryptBinaryFor('device-A', enc!);
    expect(dec, payload);
  });
}
