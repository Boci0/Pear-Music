import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/lyrics_service.dart';

void main() {
  group('LyricsService.parseLrc', () {
    test('parses standard two-digit millisecond timestamps', () {
      const lrc = '''
[00:12.34] First line
[01:02.50] Second line
[02:15.00] Third line
''';
      final lines = LyricsService.parseLrc(lrc);
      expect(lines.length, 3);
      expect(
        lines[0].timestamp,
        const Duration(minutes: 0, seconds: 12, milliseconds: 340),
      );
      expect(lines[0].text, 'First line');
      expect(
        lines[1].timestamp,
        const Duration(minutes: 1, seconds: 2, milliseconds: 500),
      );
      expect(lines[1].text, 'Second line');
      expect(lines[2].timestamp, const Duration(minutes: 2, seconds: 15));
      expect(lines[2].text, 'Third line');
    });

    test('parses three-digit millisecond timestamps', () {
      const lrc = '[00:05.123] Line with 3 digits ms';
      final lines = LyricsService.parseLrc(lrc);
      expect(lines.length, 1);
      expect(lines[0].timestamp, const Duration(seconds: 5, milliseconds: 123));
      expect(lines[0].text, 'Line with 3 digits ms');
    });

    test('parses timestamps without millisecond fraction', () {
      const lrc = '[01:30] Plain second line';
      final lines = LyricsService.parseLrc(lrc);
      expect(lines.length, 1);
      expect(lines[0].timestamp, const Duration(minutes: 1, seconds: 30));
      expect(lines[0].text, 'Plain second line');
    });

    test('parses multi-timestamp lines and sorts chronologically', () {
      const lrc = '''
[00:10.00][00:30.00] Repeated chorus line
[00:20.00] Intermediate line
''';
      final lines = LyricsService.parseLrc(lrc);
      expect(lines.length, 3);
      expect(lines[0].timestamp, const Duration(seconds: 10));
      expect(lines[0].text, 'Repeated chorus line');
      expect(lines[1].timestamp, const Duration(seconds: 20));
      expect(lines[1].text, 'Intermediate line');
      expect(lines[2].timestamp, const Duration(seconds: 30));
      expect(lines[2].text, 'Repeated chorus line');
    });

    test('handles offset tags', () {
      const lrc = '''
[offset: 500]
[00:02.00] Line after offset
''';
      final lines = LyricsService.parseLrc(lrc);
      expect(lines.length, 1);
      expect(lines[0].timestamp, const Duration(milliseconds: 2500));
    });

    test('falls back to evenly spaced lines for plain un-synced text', () {
      const text = '''
First stanza line
Second stanza line
Third stanza line
''';
      final lines = LyricsService.parseLrc(text);
      expect(lines.length, 3);
      expect(lines[0].text, 'First stanza line');
      expect(lines[1].text, 'Second stanza line');
      expect(lines[2].text, 'Third stanza line');
    });

    test('plain lyrics leave out LRC header tags but keep bracketed lyrics',
        () {
      const text = '''
[ar: Some Artist]
[ti: Some Song]
[offset: 300]
First stanza line
[Chorus: Guest]
''';
      final lines = LyricsService.parseLrc(text);
      expect(lines.map((l) => l.text), ['First stanza line', '[Chorus: Guest]']);
    });

    test('a translation or romanisation at the same time is not shown', () {
      final lines = LyricsService.parseLrc('''
[00:05.00]First original
[00:05.00]First romanised
[00:09.00]Second original
[00:09.00]Second romanised
[00:12.00]
[00:12.00]Third original
''');
      expect(lines.map((l) => l.text),
          ['First original', 'Second original', 'Third original']);
    });

    test('a space timed on its own stays between the words', () {
      final lines = LyricsService.parseLrc(
        '[00:10.00]<00:10.00>I<00:10.40> <00:10.50>said<00:11.00> <00:11.10>hey\n'
        '[00:14.00] next',
      );
      final spans = LyricsService.spansFor(lines, 0);
      expect([for (final s in spans) s.text].join(), 'I said hey');
      expect(lines.first.text, 'I said hey');
    });

    test('accepts a colon before the fraction in line timestamps', () {
      final lines = LyricsService.parseLrc('[00:12:50] Colon style');
      expect(lines.single.text, 'Colon style');
      expect(lines.single.timestamp, const Duration(milliseconds: 12500));
      expect(lines.single.timed, isTrue);
    });

    test('returns empty list for empty or whitespace content', () {
      expect(LyricsService.parseLrc(''), isEmpty);
      expect(LyricsService.parseLrc('   \n\n  \t '), isEmpty);
    });
  });

  group('LyricsService.findActiveIndex', () {
    final sampleLyrics = [
      const LyricLine(timestamp: Duration(seconds: 5), text: 'Line 1'),
      const LyricLine(timestamp: Duration(seconds: 15), text: 'Line 2'),
      const LyricLine(timestamp: Duration(seconds: 30), text: 'Line 3'),
      const LyricLine(timestamp: Duration(seconds: 45), text: 'Line 4'),
    ];

    test('returns -1 for empty lyrics', () {
      expect(
        LyricsService.findActiveIndex([], const Duration(seconds: 10)),
        -1,
      );
    });

    test('returns 0 when playback position is before the first line', () {
      expect(
        LyricsService.findActiveIndex(sampleLyrics, const Duration(seconds: 2)),
        0,
      );
    });

    test('returns correct index during line playback intervals', () {
      expect(
        LyricsService.findActiveIndex(sampleLyrics, const Duration(seconds: 5)),
        0,
      );
      expect(
        LyricsService.findActiveIndex(
          sampleLyrics,
          const Duration(seconds: 10),
        ),
        0,
      );
      expect(
        LyricsService.findActiveIndex(
          sampleLyrics,
          const Duration(seconds: 15),
        ),
        1,
      );
      expect(
        LyricsService.findActiveIndex(
          sampleLyrics,
          const Duration(seconds: 25),
        ),
        1,
      );
      expect(
        LyricsService.findActiveIndex(
          sampleLyrics,
          const Duration(seconds: 30),
        ),
        2,
      );
      expect(
        LyricsService.findActiveIndex(
          sampleLyrics,
          const Duration(seconds: 44),
        ),
        2,
      );
      expect(
        LyricsService.findActiveIndex(
          sampleLyrics,
          const Duration(seconds: 45),
        ),
        3,
      );
      expect(
        LyricsService.findActiveIndex(
          sampleLyrics,
          const Duration(seconds: 100),
        ),
        3,
      );
    });
  });

  group('LyricsService.cleanTrackTitle', () {
    test('removes official video and audio tags', () {
      expect(
        LyricsService.cleanTrackTitle('Shape of You (Official Music Video)'),
        'Shape of You',
      );
      expect(
        LyricsService.cleanTrackTitle('Blinding Lights [Official Audio]'),
        'Blinding Lights',
      );
      expect(
        LyricsService.cleanTrackTitle('Bohemian Rhapsody (Remastered 2011)'),
        'Bohemian Rhapsody',
      );
      expect(
        LyricsService.cleanTrackTitle('Artist - Track - Topic'),
        'Artist - Track',
      );
    });
  });

  group('LyricsService offset management', () {
    test('extracts offset correctly from LRC string', () {
      expect(
        LyricsService.extractOffsetMs('[offset: 500]\n[00:01.00] Test'),
        500,
      );
      expect(
        LyricsService.extractOffsetMs('[offset: -350]\n[00:01.00] Test'),
        -350,
      );
      expect(LyricsService.extractOffsetMs('[00:01.00] No offset here'), 0);
    });

    test('applies or replaces offset tag cleanly', () {
      const originalWithoutTag = '[00:01.00] Test line';
      final withTag = LyricsService.applyOffsetTag(originalWithoutTag, 250);
      expect(withTag, startsWith('[offset: 250]'));
      expect(LyricsService.extractOffsetMs(withTag), 250);

      final replaced = LyricsService.applyOffsetTag(withTag, -400);
      expect(replaced, startsWith('[offset: -400]'));
      expect(LyricsService.extractOffsetMs(replaced), -400);

      // Multiple tags in legacy files
      const duplicateTags = '[offset: 100]\n[offset: 200]\n[00:01.00] Test';
      final cleaned = LyricsService.applyOffsetTag(duplicateTags, 300);
      expect(cleaned, '[offset: 300]\n[offset: 300]\n[00:01.00] Test');
      expect(LyricsService.extractOffsetMs(cleaned), 300);
    });

    test('negative offset advances lyrics earlier', () {
      const lrc = '''
[offset: -500]
[00:02.00] Advanced line
''';
      final lines = LyricsService.parseLrc(lrc);
      expect(lines.length, 1);
      expect(lines[0].timestamp, const Duration(milliseconds: 1500));
    });
  });

  group('LrcCandidate', () {
    test('extracts first non-empty lyric line as snippet', () {
      const candidate = LrcCandidate(
        id: 1,
        trackName: 'Test',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
        hasSyncedLyrics: true,
        syncedLyrics: '''
[ti:Test]
[ar:Artist]
[00:05.00] First actual lyric line
[00:10.00] Second lyric line
''',
      );
      expect(candidate.snippet, 'First actual lyric line');
    });
  });

  group('LyricsService.compactMemory', () {
    test('clears memory cache cleanly', () {
      expect(() => LyricsService.compactMemory(), returnsNormally);
    });
  });

  group('LyricsService.getLyrics', () {
    test('cached lyrics never wait on the song length', () async {
      final song = Song(
        id: 'cached_song',
        title: 'Cached',
        fileName: 'cached.mp3',
        size: 0,
        checksum: 'x',
        addedAt: DateTime(2026, 9, 29),
      );
      LyricsService.setLyricsForTesting(song.id, '[00:01.00] Hello');
      var asked = 0;
      final lines = await LyricsService.getLyrics(
        song,
        durationLookup: () async {
          asked++;
          return const Duration(minutes: 3);
        },
      );
      expect(lines.single.text, 'Hello');
      expect(asked, 0);
      LyricsService.clearMemoryCache();
    });
  });

  group('lighting up the words', () {
    test('word timing tags become timed words and leave the text clean', () {
      final lines = LyricsService.parseLrc(
        '[00:05.00] <00:05.00>Hold <00:05.40>on <00:06.10>tight',
      );
      expect(lines.single.text, 'Hold on tight');
      expect(
        [for (final w in lines.single.words) w.start.inMilliseconds],
        [5000, 5400, 6100],
      );
      final spans = LyricsService.spansFor(lines, 0);
      expect(spans[1].start, const Duration(milliseconds: 5400));
      expect(spans[1].end, const Duration(milliseconds: 6100));
    });

    test('a closing tag marks when a held last word ends', () {
      final lines = LyricsService.parseLrc(
        '[00:05.00] <00:05.00>Hold <00:05.40>on <00:06.10>tight <00:09.20>\n'
        '[00:12.00] next',
      );
      expect(lines.first.text, 'Hold on tight');
      final spans = LyricsService.spansFor(lines, 0);
      expect(spans.last.text.trim(), 'tight');
      expect(spans.last.end, const Duration(milliseconds: 9200));
    });

    test('a repeated chorus gets its word times moved to each repeat', () {
      final lines = LyricsService.parseLrc(
        '[00:10.00][01:10.00] <00:10.00>la <00:10.50>la',
      );
      expect(lines, hasLength(2));
      expect([for (final w in lines[1].words) w.start.inMilliseconds],
          [70000, 70500]);
      expect([for (final w in lines[0].words) w.start.inMilliseconds],
          [10000, 10500]);
    });

    test('without word timing Japanese lights up one character at a time', () {
      final lines = LyricsService.parseLrc('[00:10.00] 夜に駆ける\n[00:14.00] next');
      final spans = LyricsService.spansFor(lines, 0);
      expect([for (final s in spans) s.text], ['夜', 'に', '駆', 'け', 'る']);
      expect(spans.first.start, const Duration(seconds: 10));
      for (var i = 1; i < spans.length; i++) {
        expect(spans[i].start, spans[i - 1].end);
      }
    });

    test('a fast line is squeezed in before the next one starts', () {
      final lines = LyricsService.parseLrc(
        '[00:10.00] so many words sung really quickly here\n[00:11.00] next',
      );
      final spans = LyricsService.spansFor(lines, 0);
      expect([for (final s in spans) s.text].join(), lines[0].text);
      expect(spans.last.end, lessThan(const Duration(seconds: 11)));
    });

    group('pulled onto the song\'s onsets', () {
      Duration ms(int v) => Duration(milliseconds: v);
      List<Duration> sungStarts(List<LyricSpan> spans) => [
            for (final s in spans)
              if (s.text.trim().isNotEmpty) s.start,
          ];

      test('each word starts at the onset nearest its guess', () {
        final lines = LyricsService.parseLrc(
          '[00:10.00] one two three four\n[00:14.00] next',
        );
        final guess = sungStarts(LyricsService.spansFor(lines, 0));
        // Real starts a little off each guess, in both directions.
        final real = [
          guess[0] + ms(40),
          guess[1] - ms(90),
          guess[2] + ms(120),
          guess[3] + ms(60),
        ];
        final spans = LyricsService.spansFor(lines, 0, onsets: real);
        expect(sungStarts(spans), real);
        expect([for (final s in spans) s.text].join(), lines[0].text);
        for (var i = 0; i + 1 < spans.length; i++) {
          expect(spans[i].end, spans[i + 1].start,
              reason: 'each word runs until the next starts');
        }
      });

      test('a line sung late is late throughout', () {
        final lines = LyricsService.parseLrc(
          '[00:10.00] one two three four five\n[00:16.00] next',
        );
        final guess = sungStarts(LyricsService.spansFor(lines, 0));
        // Everything 120 ms late, and the later words later still (up to
        // 360 ms, well past the 150 ms reach): each is within reach only once
        // the shift of the words before is carried.
        final real = [
          for (var i = 0; i < guess.length; i++) guess[i] + ms(120 + 60 * i),
        ];
        final spans = LyricsService.spansFor(lines, 0, onsets: real);
        expect(sungStarts(spans), real);
      });

      test('far-away onsets are ignored and order is kept', () {
        final lines = LyricsService.parseLrc(
          '[00:10.00] one two three\n[00:14.00] next',
        );
        final plain = LyricsService.spansFor(lines, 0);
        final guess = sungStarts(plain);
        final spans = LyricsService.spansFor(
          lines,
          0,
          // Only a stray onset a second away, and one past the next line.
          onsets: [guess[1] + ms(1000), ms(14100)],
        );
        expect(sungStarts(spans), guess);
      });

      test('a line buried in onsets keeps its steady estimate', () {
        final lines = LyricsService.parseLrc(
          '[00:10.00] one two three four\n[00:14.00] next',
        );
        final plain = LyricsService.spansFor(lines, 0);
        final guess = sungStarts(plain);
        // A fast guitar: an onset every 90 ms through the whole line, three
        // times as many as there are words.
        final dense = [
          for (var t = 9800; t < 13600; t += 90) ms(t),
        ];
        final spans = LyricsService.spansFor(lines, 0, onsets: dense);
        expect(sungStarts(spans), guess);
      });

      test('real word timing is never moved', () {
        final lines = LyricsService.parseLrc(
          '[00:10.00] <00:10.00>one <00:10.50>two <00:11.00>three\n[00:14.00] x',
        );
        final spans =
            LyricsService.spansFor(lines, 0, onsets: [ms(10100), ms(10600)]);
        expect(sungStarts(spans), [ms(10000), ms(10500), ms(11000)]);
      });
    });

    test('a slow line is spread over its time, up to a limit', () {
      // Five characters (about 1.1 s at a typical pace) with 3 s before the
      // next line: stretched to fill most of it.
      final slow = LyricsService.parseLrc('[00:10.00] 夜に駆ける\n[00:13.00] next');
      final slowEnd = LyricsService.spansFor(slow, 0).last.end;
      expect(slowEnd, greaterThan(const Duration(seconds: 11, milliseconds: 800)));
      expect(slowEnd, lessThanOrEqualTo(const Duration(seconds: 12, milliseconds: 600)));

      // Before a 20 s instrumental break it only stretches to 1.8x.
      final gap = LyricsService.parseLrc('[00:10.00] 夜に駆ける\n[00:30.00] next');
      expect(LyricsService.spansFor(gap, 0).last.end,
          lessThan(const Duration(seconds: 12, milliseconds: 700)));
    });

    test('a line too long for its time is sung nonstop, filling almost all of it',
        () {
      // Twelve words in 3 s cannot be sung at a typical pace: the sweep must
      // not finish early, and the last word is not held.
      const words = 'aaaaa bbbbb ccccc ddddd eeeee fffff ggggg hhhhh iiiii jjjjj kkkkk lllll';
      final lines = LyricsService.parseLrc('[00:10.00] $words\n[00:13.00] next');
      final spans = LyricsService.spansFor(lines, 0);
      final end = spans.last.end;
      expect(end, greaterThan(const Duration(seconds: 12, milliseconds: 700)));
      expect(end, lessThanOrEqualTo(const Duration(seconds: 12, milliseconds: 900)));
      final sung = spans.where((s) => s.text.trim().isNotEmpty).toList();
      final firstLen = sung.first.end - sung.first.start;
      final lastLen = sung.last.end - sung.last.start;
      expect(lastLen, lessThan(firstLen * 1.2));
    });

    test('held notes get more time: the last syllable and written stretches',
        () {
      final lines = LyricsService.parseLrc('[00:10.00] 空ーを見て\n[00:14.00] next');
      final spans = LyricsService.spansFor(lines, 0);
      Duration length(String text) {
        final s = spans.firstWhere((s) => s.text == text);
        return s.end - s.start;
      }
      expect(length('ー'), greaterThan(length('空')));
      expect(length('て'), greaterThan(length('見') * 2));
    });

    test('plain lyrics are not treated as timed', () {
      final lines = LyricsService.parseLrc('first line\nsecond line');
      expect(lines.every((l) => !l.timed), isTrue);
    });
  });

  group('picking lyrics on its own', () {
    LrcCandidate candidate(
      String track,
      String artist,
      double seconds, {
      bool synced = true,
    }) => LrcCandidate(
      id: track.hashCode,
      trackName: track,
      artistName: artist,
      albumName: '',
      duration: seconds,
      hasSyncedLyrics: synced,
      syncedLyrics: synced ? '[00:01.00] line' : null,
      plainLyrics: 'line',
    );

    const title = 'Curi Curi Pandang - Maman Fvndy';
    const length = Duration(seconds: 198);

    test(
      'the right song outranks another song that merely has synced lyrics',
      () {
        final right = candidate(
          'Curi Curi Pandang',
          'Maman Fvndy',
          197,
          synced: false,
        );
        final other = candidate('Pandang', 'Someone Else', 240);
        expect(
          LyricsService.matchScore(right, title, duration: length),
          greaterThan(LyricsService.matchScore(other, title, duration: length)),
        );
      },
    );

    test('the version whose length matches wins, even with the artist '
        'written differently', () {
      const title = '忘れてやらない - Never forget - kessoku band';
      const length = Duration(seconds: 222);
      final sameLength = candidate('忘れてやらない', '結束バンド', 223);
      final musicVideo = candidate('忘れてやらない', 'Kessoku Band', 236);
      expect(
        LyricsService.matchScore(sameLength, title, duration: length),
        greaterThan(LyricsService.matchScore(musicVideo, title, duration: length)),
      );
    });

    test('synced lyrics win between two versions of the same song', () {
      final plain = candidate(
        'Curi Curi Pandang',
        'Maman Fvndy',
        198,
        synced: false,
      );
      final synced = candidate('Curi Curi Pandang', 'Maman Fvndy', 199);
      expect(
        LyricsService.matchScore(synced, title, duration: length),
        greaterThan(LyricsService.matchScore(plain, title, duration: length)),
      );
    });

    test('only a real match is applied without asking', () {
      expect(
        LyricsService.isConfidentMatch(
          candidate('Curi Curi Pandang', 'Maman Fvndy', 197),
          title,
          duration: length,
        ),
        isTrue,
      );
      // A different song.
      expect(
        LyricsService.isConfidentMatch(
          candidate('Pandang Aku', 'Someone Else', 198),
          title,
          duration: length,
        ),
        isFalse,
      );
      // The same name but a much longer recording (an extended mix).
      expect(
        LyricsService.isConfidentMatch(
          candidate('Curi Curi Pandang', 'Maman Fvndy', 320),
          title,
          duration: length,
        ),
        isFalse,
      );
    });
  });

  group('LyricsService.timingReport', () {
    final song = Song(
      id: 'report_song',
      title: 'Report',
      fileName: 'report.mp3',
      size: 0,
      checksum: 'x',
      addedAt: DateTime(2026, 9, 30),
    );

    test('reads the source mark back and never holds lyric text', () {
      final raw = '[00:01.00] placeholder\n${LyricsService.sourceMark('netease')}';
      expect(LyricsService.sourceOf(raw), 'netease');
      expect(LyricsService.sourceOf('[00:01.00] x'), isNull);
      final lines = LyricsService.parseLrc(raw);
      expect(lines.length, 1);
      expect(lines.single.text, 'placeholder');
    });

    test('reports estimated timing, the offset and the current line', () {
      final lines = LyricsService.parseLrc(
        '[00:10.00] alpha beta\n[00:20.00] gamma delta',
      );
      final report = LyricsService.timingReport(
        song: song,
        songLength: const Duration(minutes: 3, seconds: 5),
        position: const Duration(seconds: 12, milliseconds: 500),
        lyrics: lines,
        offsetMs: -200,
        source: 'LRCLIB',
        onsets: const [],
      );
      expect(report, contains('Song id: report_song'));
      expect(report, contains('Song length: 3:05.000'));
      expect(report, contains('Lyrics source: LRCLIB'));
      expect(report, contains('Timing offset: -200ms'));
      expect(report, contains('Current line: #1 at 0:10.000 (+2500ms'));
      expect(report, contains('Next line at: 0:20.000'));
      expect(report, contains('Word timing: estimated'));
      expect(report, contains('no onsets found'));
      expect(report, isNot(contains('alpha')));
    });

    test('reports real word timing', () {
      final lines = LyricsService.parseLrc(
        '[00:10.00] <00:10.00> alpha <00:10.50> beta',
      );
      final report = LyricsService.timingReport(
        song: song,
        songLength: null,
        position: const Duration(seconds: 11),
        lyrics: lines,
        offsetMs: 0,
        source: 'NetEase',
      );
      expect(report, contains('Song length: unknown'));
      expect(report, contains('Word timing: real (2 words)'));
      expect(report, contains('Next line at: none'));
    });

    test('says so before the first line', () {
      final report = LyricsService.timingReport(
        song: song,
        songLength: null,
        position: Duration.zero,
        lyrics: LyricsService.parseLrc('[00:10.00] alpha'),
        offsetMs: 0,
        source: 'LRCLIB',
      );
      expect(report, contains('Current line: none yet'));
    });
  });
}
