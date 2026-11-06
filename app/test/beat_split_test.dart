import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/visualizer_feed.dart';
import 'package:peerm_app/widgets/beat_split.dart';

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
    expect(e.level, 0, reason: 'steady bass does not split');
    final hit = e.step(0.6, 1);
    expect(hit, greaterThan(0.8));
    for (var i = 0; i < 45; i++) {
      e.step(0.2, 1);
    }
    expect(e.level, 0);
  });

  testWidgets('the colours split on a kick and only while switched on', (
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
    // How far the colours are split, 0 at rest.
    double split() =>
        (tester.state(find.byType(BeatSplit)) as dynamic).debugSplit as double;

    Future<void> mount(bool on) => tester.pumpWidget(
      BeatSplit(
        enabled: on,
        player: player,
        child: const SizedBox(width: 10, height: 10),
      ),
    );

    feed.debugSetNativeFft(true);
    addTearDown(() => feed.debugSetNativeFft(false));

    await mount(false);
    bass(0.9);
    await tester.pump(const Duration(milliseconds: 16));
    expect(split(), 0, reason: 'off: nothing splits');

    await mount(true);
    bass(0.1);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(split(), 0, reason: 'steady bass: no split');

    bass(0.9);
    await tester.pump(const Duration(milliseconds: 16));
    final first = split();
    await tester.pump(const Duration(milliseconds: 16));
    expect(first, greaterThan(0), reason: 'kick: it splits at once');
    expect(split(), greaterThan(first), reason: 'and eases in');

    bass(0.1);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(split(), 0, reason: 'and fades back');

    await tester.pumpWidget(const SizedBox.shrink());
    bass(0);
  });
}
