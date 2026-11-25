import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/visualizer_feed.dart';
import 'package:peerm_app/widgets/beat_sparks.dart';

class _FakePlayer extends ChangeNotifier implements PlayerService {
  final _pos = StreamController<Duration>.broadcast();
  @override
  bool get playing => true;
  @override
  Duration? get position => Duration.zero;
  @override
  Stream<Duration> get positionStream => _pos.stream;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a kick jumps the level and it falls away', () {
    final e = BeatEnvelope();
    for (var i = 0; i < 60; i++) {
      e.step(0.2, 1);
    }
    expect(e.level, 0, reason: 'steady bass sets off nothing');
    final hit = e.step(0.6, 1);
    expect(hit, greaterThan(0.8));
    for (var i = 0; i < 45; i++) {
      e.step(0.2, 1);
    }
    expect(e.level, 0);
  });

  test('the first sample after a reset is not a hit', () {
    final e = BeatEnvelope();
    expect(e.step(0.8, 1), 0);
    expect(e.hit, isFalse);
    e.reset();
    expect(e.step(0.8, 1), 0);
  });

  testWidgets('sparks fly on a kick and only while switched on', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'system_audio_visualizer/methods',
      'system_audio_visualizer/fft',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    final feed = VisualizerFeed.instance;
    final player = _FakePlayer();
    void bass(double v) => feed.targetBins.fillRange(0, 3, v);
    // How many sparks are in the air, 0 at rest.
    int sparks() =>
        (tester.state(find.byType(BeatSparks)) as dynamic).debugSparkCount
            as int;
    Future<void> pump(int n) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Future<void> mount(bool on) =>
        tester.pumpWidget(BeatSparks(enabled: on, player: player));

    feed.debugSetNativeFft(true);
    addTearDown(() => feed.debugSetNativeFft(false));

    await mount(false);
    bass(0.9);
    await pump(1);
    expect(sparks(), 0, reason: 'off: no sparks');

    await mount(true);
    bass(0.1);
    await pump(40);
    expect(sparks(), 0, reason: 'steady bass: no sparks');

    bass(0.9);
    await pump(1);
    expect(sparks(), inInclusiveRange(1, 3), reason: 'kick: a small burst');

    bass(0.1);
    await pump(1100);
    expect(sparks(), 0, reason: 'and they all fade out');

    await tester.pumpWidget(const SizedBox.shrink());
    bass(0);
  });

  testWidgets('a rise outside the kick and snare bands sends sparks', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'system_audio_visualizer/methods',
      'system_audio_visualizer/fft',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    final feed = VisualizerFeed.instance;
    final player = _FakePlayer();
    int sparks() =>
        (tester.state(find.byType(BeatSparks)) as dynamic).debugSparkCount
            as int;
    Future<void> pump(int n) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    feed.debugSetNativeFft(true);
    addTearDown(() => feed.debugSetNativeFft(false));

    await tester.pumpWidget(BeatSparks(enabled: true, player: player));
    feed.targetBins.fillRange(0, feed.targetBins.length, 0.1);
    await pump(40);
    expect(sparks(), 0, reason: 'steady: no sparks');

    feed.targetBins.fillRange(14, 20, 0.9);
    await pump(2);
    expect(sparks(), greaterThan(0), reason: 'a high-band rise sends sparks');

    feed.targetBins.fillRange(14, 20, 0.1);
    await pump(1100);
    expect(sparks(), 0, reason: 'and they fade out');

    await tester.pumpWidget(const SizedBox.shrink());
    feed.targetBins.fillRange(0, feed.targetBins.length, 0);
  });
}
