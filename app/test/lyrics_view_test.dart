import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/lyrics_display.dart';
import 'package:peerm_app/services/lyrics_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/widgets/player/lyrics_view.dart';

/// An engine parked at [position_] whose position stream a test drives.
class _FakePlayer extends AudioPlayer {
  _FakePlayer() : super(handleAudioSessionActivation: false);

  Duration position_ = Duration.zero;
  final StreamController<Duration> positions = StreamController.broadcast();

  @override
  Duration get position => position_;

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  bool get playing => false;

  @override
  Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) => positions.stream;
}

void main() {
  final song = Song(
    id: 'lyrics_view_song',
    title: 'Line Song - Tester',
    fileName: 'line.m4a',
    size: 1,
    checksum: 'x',
    addedAt: DateTime(2026, 9, 29),
  );
  const lrc = '''
[00:00.00] Line one
[00:05.00] Line <00:05.00>two <00:06.00>has <00:07.00>words
[00:10.00] Line three
''';

  setUp(() => LyricsService.setLyricsForTesting(song.id, lrc));
  tearDown(LyricsService.clearMemoryCache);

  /// The opacity each piece of [text] is drawn with, in order.
  List<double> pieceAlphas(WidgetTester tester, String text) {
    final rich = tester.widget<Text>(find.text(text)).textSpan! as TextSpan;
    return [for (final s in rich.children!) s.style!.color!.a];
  }

  Future<void> pumpLyrics(
    WidgetTester tester, {
    Duration at = const Duration(seconds: 6, milliseconds: 500),
    double bottomInset = 0,
  }) async {
    final engine = _FakePlayer()..position_ = at;
    final player = PlayerService(LibraryService(), player: engine);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 320,
            height: 320,
            child: LyricsView(
              song: song,
              player: player,
              size: 320,
              bottomInset: bottomInset,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('word timing tags are read, not shown', (tester) async {
    await pumpLyrics(tester);
    expect(find.text('Line two has words'), findsOneWidget);
    expect(find.textContaining('<00:'), findsNothing);
  });

  testWidgets('"Off" draws no frames while nothing is animating', (
    tester,
  ) async {
    LyricsDisplay.wordGlow.value = WordGlowMode.off;
    addTearDown(() => LyricsDisplay.wordGlow.value = WordGlowMode.estimated);
    await pumpLyrics(tester, at: const Duration(seconds: 11));
    final text = tester.widget<Text>(find.text('Line three'));
    expect(text.textSpan, isNull, reason: 'plain text, no per-word pieces');
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: 'nothing is animating, so no frames are drawn');
  });

  testWidgets('a sweeping line keeps drawing frames', (tester) async {
    await pumpLyrics(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('a line without word timing falls back to estimated word by '
      'word', (tester) async {
    await pumpLyrics(tester, at: const Duration(seconds: 11));
    final rich =
        tester.widget<Text>(find.text('Line three')).textSpan! as TextSpan;
    expect(rich.children, isNotEmpty);
  });

  testWidgets('"Off" lights even a word-timed line all at once', (
    tester,
  ) async {
    LyricsDisplay.wordGlow.value = WordGlowMode.off;
    addTearDown(() => LyricsDisplay.wordGlow.value = WordGlowMode.estimated);
    await pumpLyrics(tester);
    expect(tester.widget<Text>(find.text('Line two has words')).textSpan,
        isNull);
  });

  testWidgets('with black text the sung words light up in colour', (
    tester,
  ) async {
    LyricsDisplay.mode.value = LyricsColorMode.dark;
    addTearDown(() => LyricsDisplay.mode.value = LyricsColorMode.auto);
    await pumpLyrics(tester);
    final rich =
        tester.widget<Text>(find.text('Line two has words')).textSpan!
            as TextSpan;
    final sung = rich.children!.first.style!;
    final upcoming = rich.children!.last.style!;
    expect(sung.color, isNot(const Color(0xFF141416)));
    expect(sung.shadows, isNotEmpty);
    expect(upcoming.shadows, isNull);
  });

  testWidgets('the words light up as they are sung', (tester) async {
    await pumpLyrics(tester);
    // At 6.5 s: "two" is sung, "has" is half way, "words" is still to come.
    final alphas = pieceAlphas(tester, 'Line two has words');
    expect(alphas.first, closeTo(1, 0.01));
    expect(alphas[1], lessThan(1));
    expect(alphas[1], greaterThan(alphas.last));
    expect(alphas.last, closeTo(0.30, 0.01));
  });

  testWidgets(
    'the line sits at the card centre with or without the visualizer',
    (tester) async {
      await pumpLyrics(tester, at: const Duration(seconds: 11));
      final centre = tester.getCenter(find.byType(LyricsView)).dy;
      expect(tester.getCenter(find.text('Line three')).dy, closeTo(centre, 2));

      await pumpLyrics(
        tester,
        at: const Duration(seconds: 11),
        bottomInset: 108,
      );
      expect(tester.getCenter(find.text('Line three')).dy, closeTo(centre, 2));
    },
  );

  testWidgets('a long line shrinks to stay clear of the bars', (tester) async {
    LyricsService.setLyricsForTesting(
      song.id,
      '[00:00.00] ${List.filled(30, 'many words').join(' ')}',
    );
    await pumpLyrics(tester, at: const Duration(seconds: 1), bottomInset: 108);
    final card = tester.getRect(find.byType(LyricsView));
    final line = tester.getRect(find.byType(RichText).last);
    expect(line.bottom, lessThanOrEqualTo(card.bottom - 108 + 1));
    expect(line.top, greaterThanOrEqualTo(card.top + 108 - 1));
  });
}
