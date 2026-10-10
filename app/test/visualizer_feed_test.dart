import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/debug_log.dart';
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
    for (final name in [
      'system_audio_visualizer/methods',
      'system_audio_visualizer/fft',
    ]) {
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

  group('Windows capture logging', () {
    const method = MethodChannel('system_audio_visualizer/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      // Back to the quiet mock the other tests rely on.
      messenger.setMockMethodCallHandler(method, (_) async => null);
    });

    testWidgets('a capture that cannot start says so in the debug log',
        (tester) async {
      messenger.setMockMethodCallHandler(method, (call) async {
        if (call.method == 'start') {
          throw PlatformException(code: 'no_device', message: 'no output device');
        }
        return null;
      });
      DebugLog.clearRecent();
      final feed = VisualizerFeed.instance;
      final player = _FakePlayer(isPlaying: true);

      feed.acquire(player);
      // The mocked channel answers on the real event loop, a few turns later.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();

      expect(
        DebugLog.recentLogs.any((l) => l.contains('Windows capture could not start')),
        isTrue,
        reason: DebugLog.recentLogs.join(' | '),
      );
      expect(
        DebugLog.recentLogs.any((l) => l.contains('no_device')),
        isTrue,
        reason: 'the cause is in the line',
      );

      feed.release();
      player.dispose();
    }, skip: !Platform.isWindows);

    testWidgets('a capture that starts but delivers nothing is called out',
        (tester) async {
      messenger.setMockMethodCallHandler(method, (_) async => null);
      DebugLog.clearRecent();
      final feed = VisualizerFeed.instance;
      final player = _FakePlayer(isPlaying: true);

      feed.acquire(player);
      await tester.pump(const Duration(seconds: 2));
      expect(
        DebugLog.recentLogs.any((l) => l.contains('no spectrum frames')),
        isFalse,
        reason: 'not before the timeout',
      );

      await tester.pump(const Duration(seconds: 3));
      expect(
        DebugLog.recentLogs.any((l) => l.contains('no spectrum frames')),
        isTrue,
        reason: DebugLog.recentLogs.join(' | '),
      );

      // Said once, and stopping the capture leaves no timer behind.
      await tester.pump(const Duration(seconds: 10));
      expect(
        DebugLog.recentLogs.where((l) => l.contains('no spectrum frames')).length,
        1,
      );
      feed.release();
      player.dispose();
    }, skip: !Platform.isWindows);

    testWidgets('stopping before the timeout says nothing', (tester) async {
      messenger.setMockMethodCallHandler(method, (_) async => null);
      DebugLog.clearRecent();
      final feed = VisualizerFeed.instance;
      final player = _FakePlayer(isPlaying: true);

      feed.acquire(player);
      await tester.pump(const Duration(seconds: 1));
      feed.release();
      await tester.pump(const Duration(seconds: 10));

      expect(
        DebugLog.recentLogs.any((l) => l.contains('no spectrum frames')),
        isFalse,
      );
      player.dispose();
    }, skip: !Platform.isWindows);
  });

  testWidgets(
      'MiniVisualizer wakes when the spectrum arrives after playback started',
      (tester) async {
    final feed = VisualizerFeed.instance;
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
    double activity() =>
        (tester.state(find.byType(MiniVisualizer)) as dynamic).debugActivity
            as double;

    // The widget's timer runs on fake time and its physics read the real
    // clock, so a test has to move both.
    Future<void> elapse(int times) async {
      for (var i = 0; i < times; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    // Playing, but the capture has not delivered a frame yet: nothing grows.
    await elapse(5);
    expect(activity(), 0.0);

    // The first frames arrive; the bars must start without any other nudge.
    feed.processFft(List<double>.filled(64, 0.6));
    feed.debugSetNativeFft(true);
    addTearDown(() => feed.debugSetNativeFft(false));
    await elapse(10);
    expect(activity(), greaterThan(0.2));

    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
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
