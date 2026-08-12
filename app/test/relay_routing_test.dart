import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/relay_data_channel.dart';
import 'package:peerm_app/services/signaling_server.dart';
import 'package:peerm_app/services/signaling_service.dart';
import 'package:peerm_app/services/sync_service.dart';
import 'package:peerm_app/services/youtube_service.dart';

/// A [RelayDataChannel] that records the binary frames (and their encryption
/// flag) routed to it, so routing between multiple peers can be asserted.
class _RoutingChannel extends RelayDataChannel {
  _RoutingChannel({required super.peerId, required super.signaling});

  final List<Uint8List> binaryFrames = [];
  final List<bool> binaryEnc = [];

  @override
  Future<void> handleRelayBinary(Uint8List bytes,
      {bool encrypted = false}) async {
    binaryFrames.add(bytes);
    binaryEnc.add(encrypted);
  }
}

/// A plain [AppController] so the real `_onServerMessage` routing runs, driven
/// through the [AppController.handleServerMessage] test seam.
class _TestController extends AppController {
  _TestController({
    required super.identity,
    required super.library,
    required super.signaling,
    required super.sync,
    required super.player,
    required super.youtube,
    required super.server,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestController controller;
  late SignalingService signaling;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final tempDir = await Directory.systemTemp.createTemp('peerm-relay-test');
    final library = LibraryService()..debugBaseDirectory = tempDir;
    await library.init();
    signaling = SignalingService(identity);
    final sync = SyncService(identity: identity, library: library);
    final player = PlayerService(library);
    controller = _TestController(
      identity: identity,
      library: library,
      signaling: signaling,
      sync: sync,
      player: player,
      youtube: YoutubeService(),
      server: SignalingServer(port: 8080),
    );
  });

  test(
      'concurrent binary relays from two senders are not mis-routed '
      '(FIFO marker matching)', () async {
    final chB = _RoutingChannel(peerId: 'device-B', signaling: signaling);
    final chC = _RoutingChannel(peerId: 'device-C', signaling: signaling);
    controller.attachRelayChannelForTesting('device-B', chB);
    controller.attachRelayChannelForTesting('device-C', chC);

    // The server relays marker+frame from B and C interleaved: B's marker,
    // C's marker, then B's raw frame, then C's raw frame. Each raw frame must
    // be paired with ITS OWN marker (a single "latest marker" slot would route
    // B's frame to C, failing decryption and dropping the chunk).
    await controller.handleServerMessage({
      'type': 'relay',
      'from': 'device-B',
      'data': {'t': 'bin', 'e': 1},
    });
    await controller.handleServerMessage({
      'type': 'relay',
      'from': 'device-C',
      'data': {'t': 'bin'},
    });
    final frameB = Uint8List.fromList([1, 2, 3]);
    final frameC = Uint8List.fromList([9, 8, 7]);
    await controller.handleServerMessage({
      'type': '_local',
      'event': 'binary',
      'bytes': frameB,
    });
    await controller.handleServerMessage({
      'type': '_local',
      'event': 'binary',
      'bytes': frameC,
    });

    // B's frame is routed to B with its `e:1` flag intact; C's to C without.
    expect(chB.binaryFrames, [frameB]);
    expect(chB.binaryEnc, [true]);
    expect(chC.binaryFrames, [frameC]);
    expect(chC.binaryEnc, [false]);
  });

  test('markers can be queued before any frame arrives (deep FIFO)', () async {
    final chB = _RoutingChannel(peerId: 'device-B', signaling: signaling);
    final chC = _RoutingChannel(peerId: 'device-C', signaling: signaling);
    controller.attachRelayChannelForTesting('device-B', chB);
    controller.attachRelayChannelForTesting('device-C', chC);

    // Three markers queued up-front (B, C, B), then three frames in the same
    // order — each frame must match the oldest unmatched marker.
    await controller.handleServerMessage({
      'type': 'relay',
      'from': 'device-B',
      'data': {'t': 'bin', 'e': 1},
    });
    await controller.handleServerMessage({
      'type': 'relay',
      'from': 'device-C',
      'data': {'t': 'bin', 'e': 1},
    });
    await controller.handleServerMessage({
      'type': 'relay',
      'from': 'device-B',
      'data': {'t': 'bin'},
    });
    final b1 = Uint8List.fromList([1]);
    final c = Uint8List.fromList([2]);
    final b2 = Uint8List.fromList([3]);
    await controller.handleServerMessage(
        {'type': '_local', 'event': 'binary', 'bytes': b1});
    await controller.handleServerMessage(
        {'type': '_local', 'event': 'binary', 'bytes': c});
    await controller.handleServerMessage(
        {'type': '_local', 'event': 'binary', 'bytes': b2});

    expect(chB.binaryFrames, [b1, b2]);
    expect(chB.binaryEnc, [true, false]);
    expect(chC.binaryFrames, [c]);
    expect(chC.binaryEnc, [true]);
  });

  test('text relay routes to the peer named by the marker', () async {
    final chB = _RoutingChannel(peerId: 'device-B', signaling: signaling);
    controller.attachRelayChannelForTesting('device-B', chB);
    final received = <String>[];
    chB.onMessage = (m) => received.add(m.text);

    await controller.handleServerMessage({
      'type': 'relay',
      'from': 'device-B',
      'data': {'t': 'text', 'd': '{"type":"hello"}'},
    });

    expect(received, ['{"type":"hello"}']);
  });

  test('binary frames with no matching marker are dropped safely', () async {
    final chB = _RoutingChannel(peerId: 'device-B', signaling: signaling);
    controller.attachRelayChannelForTesting('device-B', chB);

    // A frame with no preceding marker must not crash and must not route.
    await controller.handleServerMessage({
      'type': '_local',
      'event': 'binary',
      'bytes': Uint8List.fromList([0x50, 0x00, 0x01]),
    });

    expect(chB.binaryFrames, isEmpty);
  });
}
