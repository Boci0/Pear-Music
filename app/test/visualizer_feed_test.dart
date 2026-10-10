import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/visualizer_feed.dart';
import 'package:peerm_app/widgets/player/mini_visualizer.dart';

class _FakePlayer extends ChangeNotifier implements PlayerService {
  _FakePlayer({this.isPlaying = false});
  bool isPlaying;
  final _pos = StreamController<Duration>.broadcast();

  @override
  bool get playing => isPlaying;
  @override
  Duration? get position => Duration.zero;
  @override
  Stream<Duration> get positionStream => _pos.stream;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // The Windows capture plugin does not exist under test: answer its
    // channels instead of letting the missing plugin raise.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['system_audio_visualizer', 'system_audio_visualizer/fft']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  group('VisualizerFeed', () {
    final feed = VisualizerFeed.instance;

    test('a loud frame moves every band and silence shuts them all off', () {
      feed.processFft(List<double>.filled(64, 0.6));
      expect(feed.targetBins.every((v) => v > 0), isTrue);

      feed.processFft(List<double>.filled(64, 0.005));
      expect(feed.targetBins.every((v) => v == 0), isTrue);
    });

    test('capture is held while any visualizer is on screen', () {
      final player = _FakePlayer();
      expect(feed.clientCount, 0);
      feed.acquire(player);
      feed.acquire(player);
      expect(feed.clientCount, 2);
      feed.release();
      expect(feed.clientCount, 1);
      feed.release();
      expect(feed.clientCount, 0);
      feed.release(); // never goes negative
      expect(feed.clientCount, 0);
      player.dispose();
    });

    test('the made-up pattern stays off while the question is on screen',
        () async {
      final player = _FakePlayer(isPlaying: true);
      feed.acquire(player);
      addTearDown(feed.release);

      feed.awaitingPermission = true;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      feed.refresh();
      expect(feed.targetBins.every((v) => v == 0), isTrue);

      feed.awaitingPermission = false;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      feed.refresh();
      expect(feed.targetBins.any((v) => v > 0), isTrue,
          reason: 'with no native spectrum the stand-in pattern is used');
      player.dispose();
    });
  });

  group('SpectrumPhysics', () {
    Future<void> run(SpectrumPhysics p, int steps,
        {required bool playing, required List<double> targets}) async {
      for (var i = 0; i < steps; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        p.step(playing: playing, targets: targets);
      }
    }

    test('bars grow in from nothing and settle once playback stops', () async {
      final p = SpectrumPhysics();
      final targets = List<double>.filled(VisualizerFeed.barCount, 0.8);
      expect(p.activity, 0.0);

      await run(p, 25, playing: true, targets: targets);
      expect(p.activity, 1.0);
      expect(p.display.every((v) => v > 0.3), isTrue);

      var settled = false;
      for (var i = 0; i < 80 && !settled; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        settled = p.step(playing: false, targets: targets);
      }
      expect(settled, isTrue);
      expect(p.display.every((v) => v == 0), isTrue);
    });

    test('the middle bars follow the bass and the edges follow the treble',
        () async {
      final p = SpectrumPhysics();
      final targets = List<double>.filled(VisualizerFeed.barCount, 0.0);
      targets[0] = 1.0; // bass only
      await run(p, 40, playing: true, targets: targets);
      final centre = p.display[VisualizerFeed.barCount ~/ 2];
      final edge = p.display[0];
      expect(centre, greaterThan(edge));
    });
  });

  testWidgets('MiniVisualizer mounts, plays and unmounts cleanly',
      (tester) async {
    final player = _FakePlayer(isPlaying: true);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 64,
          child: MiniVisualizer(player: player, color: Colors.teal),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(MiniVisualizer), findsOneWidget);

    player.isPlaying = false;
    player.notifyListeners();
    await tester.pump(const Duration(milliseconds: 600));

    await tester.pumpWidget(const SizedBox.shrink());
    expect(VisualizerFeed.instance.clientCount, 0);
    expect(tester.takeException(), isNull);
    player.dispose();
  });
}
