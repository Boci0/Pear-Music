import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/window_focus.dart';
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

  testWidgets('ArtworkVisualizer survives window focus changes while playing',
      (tester) async {
    final player = _FakePlayerService();
    addTearDown(() => WindowFocus.focused.value = true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 150,
            child: ArtworkVisualizer(
              player: player,
              accentColor: Colors.teal,
            ),
          ),
        ),
      ),
    );

    player.setPlaying(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Losing focus must stop the ticker and capture without errors.
    WindowFocus.focused.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(ArtworkVisualizer), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Regaining focus resumes rendering.
    WindowFocus.focused.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(ArtworkVisualizer), findsOneWidget);
    expect(tester.takeException(), isNull);

    player.setPlaying(false);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
  });


  testWidgets('a cover bakes into the band behind the wave and is optional',
      (tester) async {
    final player = _FakePlayerService();
    late final Uint8List png;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 40, 40),
        Paint()..color = const Color(0xFF3366CC),
      );
      final image = await recorder.endRecording().toImage(40, 40);
      png = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
    });

    Widget host({ImageProvider? cover, bool bright = false}) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 150,
              child: ArtworkVisualizer(
                player: player,
                accentColor: Colors.teal,
                onBrightArt: bright,
                cover: cover,
              ),
            ),
          ),
        );

    await tester.pumpWidget(host());
    final state = tester.state(find.byType(ArtworkVisualizer)) as dynamic;
    expect(state.debugHasBand as bool, isFalse);

    await tester.pumpWidget(host(cover: MemoryImage(png)));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(state.debugHasBand as bool, isTrue);

    // A change of polarity re-bakes from the kept cover.
    await tester.pumpWidget(host(cover: MemoryImage(png), bright: true));
    await tester.pump();
    expect(state.debugHasBand as bool, isTrue);

    // Losing the cover falls back to the plain shade.
    await tester.pumpWidget(host());
    await tester.pump();
    expect(state.debugHasBand as bool, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
  });
}
