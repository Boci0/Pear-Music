import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/widgets/player/rhythm_pulse.dart';

class FakePlayerService extends ChangeNotifier implements PlayerService {
  bool _playing = false;

  @override
  bool get playing => _playing;

  void setPlaying(bool val) {
    if (_playing == val) return;
    _playing = val;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('RhythmPulseBuilder stays idle when not playing', (tester) async {
    final player = FakePlayerService();
    double lastAura = -1.0;

    await tester.pumpWidget(
      MaterialApp(
        home: RhythmPulseBuilder(
          player: player,
          builder: (context, aura, child) {
            lastAura = aura;
            return Container();
          },
        ),
      ),
    );

    expect(lastAura, 0.0);
    // Pump 1 second, verify no frames / aura remains 0.0
    await tester.pump(const Duration(seconds: 1));
    expect(lastAura, 0.0);
  });

  testWidgets('RhythmPulseBuilder pulses when playing and stops completely when paused',
      (tester) async {
    final player = FakePlayerService();
    double lastAura = 0.0;
    int buildCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: RhythmPulseBuilder(
          player: player,
          builder: (context, aura, child) {
            lastAura = aura;
            buildCount++;
            return Container();
          },
        ),
      ),
    );

    expect(lastAura, 0.0);
    final initialBuilds = buildCount;

    // Start playback
    player.setPlaying(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(lastAura, greaterThan(0.0));
    final playingBuilds = buildCount;
    expect(playingBuilds, greaterThan(initialBuilds));

    // Pause playback
    player.setPlaying(false);
    await tester.pump();

    // Advance 600ms (past the 500ms reverse fade duration)
    await tester.pump(const Duration(milliseconds: 600));
    expect(lastAura, 0.0);

    final buildsAfterPause = buildCount;

    // Pump further while paused; no further rebuilds should occur
    await tester.pump(const Duration(seconds: 2));
    expect(buildCount, buildsAfterPause);
    expect(lastAura, 0.0);
  });
}
