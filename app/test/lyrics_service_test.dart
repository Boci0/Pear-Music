import 'package:flutter_test/flutter_test.dart';
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
      expect(lines[0].timestamp, const Duration(minutes: 0, seconds: 12, milliseconds: 340));
      expect(lines[0].text, 'First line');
      expect(lines[1].timestamp, const Duration(minutes: 1, seconds: 2, milliseconds: 500));
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
      expect(LyricsService.findActiveIndex([], const Duration(seconds: 10)), -1);
    });

    test('returns 0 when playback position is before the first line', () {
      expect(LyricsService.findActiveIndex(sampleLyrics, const Duration(seconds: 2)), 0);
    });

    test('returns correct index during line playback intervals', () {
      expect(LyricsService.findActiveIndex(sampleLyrics, const Duration(seconds: 5)), 0);
      expect(LyricsService.findActiveIndex(sampleLyrics, const Duration(seconds: 10)), 0);
      expect(LyricsService.findActiveIndex(sampleLyrics, const Duration(seconds: 15)), 1);
      expect(LyricsService.findActiveIndex(sampleLyrics, const Duration(seconds: 25)), 1);
      expect(LyricsService.findActiveIndex(sampleLyrics, const Duration(seconds: 30)), 2);
      expect(LyricsService.findActiveIndex(sampleLyrics, const Duration(seconds: 44)), 2);
      expect(LyricsService.findActiveIndex(sampleLyrics, const Duration(seconds: 45)), 3);
      expect(LyricsService.findActiveIndex(sampleLyrics, const Duration(seconds: 100)), 3);
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
}
