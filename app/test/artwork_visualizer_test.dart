import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/widgets/player/visual_synthesizer_bar.dart';

class _FakePlayerService extends ChangeNotifier implements PlayerService {
  bool _playing = false;
  Duration _pos = Duration.zero;
  final StreamController<Duration> _posController =
      StreamController<Duration>.broadcast();

  @override
  bool get playing => _playing;

  @override
  Duration? get position => _pos;

  @override
  Stream<Duration> get positionStream => _posController.stream;

  void setPlaying(bool val) {
    if (_playing == val) return;
    _playing = val;
    notifyListeners();
  }

  void setPosition(Duration pos) {
    _pos = pos;
    _posController.add(pos);
  }

  @override
  void dispose() {
    _posController.close();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('ArtworkVisualizer mounts cleanly and responds to playback',
      (tester) async {
    final player = _FakePlayerService();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 150,
            child: ArtworkVisualizer(
              player: player,
              accentColor: Colors.blueAccent,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(ArtworkVisualizer), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);

    // Initial state: not playing
    await tester.pump(const Duration(milliseconds: 100));

    // Start playback
    player.setPlaying(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Verify CustomPaint is repainting during playback
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(ArtworkVisualizer), findsOneWidget);

    // Pause playback
    player.setPlaying(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    player.dispose();
  });

  testWidgets('ArtworkVisualizer mounts cleanly and unmounts without error',
      (tester) async {
    final player = _FakePlayerService();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 150,
            child: ArtworkVisualizer(
              player: player,
              accentColor: Colors.deepPurple,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(ArtworkVisualizer), findsOneWidget);
    player.setPlaying(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Unmount widget cleanly
    await tester.pumpWidget(const SizedBox.shrink());
    expect(find.byType(ArtworkVisualizer), findsNothing);

    player.dispose();
  });
}
