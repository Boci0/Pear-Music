import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/lyrics_service.dart';
import 'package:peerm_app/services/netease_lyrics.dart';

void main() {
  group('NetEase word-timed lyrics', () {
    // The shape NetEase returns: a JSON credits block, a credit line, then
    // lines of (start, length, 0) timed words, all in milliseconds.
    const yrc = '''
{"t":0,"c":[{"tx":"作词: "},{"tx":"ZAQ"}]}
[0,476](0,476,0)作词 : ZAQ
[12000,3400](12000,400,0)忘(12400,300,0)れ(12700,300,0)て(13000,1800,0)や
[16000,2000](16000,500,0)(Cover (16500,500,0)us)
''';

    test('converts to LRC the app reads, credits left out', () {
      final lines = LyricsService.parseLrc(NeteaseLyrics.yrcToEnhancedLrc(yrc));
      expect([for (final l in lines) l.text], ['忘れてや', '(Cover us)']);
      expect(lines.first.timestamp, const Duration(seconds: 12));
      expect(
        [for (final w in lines.first.words) w.start.inMilliseconds],
        [12000, 12400, 12700, 13000],
      );
    });

    test('a held last word keeps its real length', () {
      final lines = LyricsService.parseLrc(NeteaseLyrics.yrcToEnhancedLrc(yrc));
      final spans = LyricsService.spansFor(lines, 0);
      // 「や」 is held for 1.8 s, not guessed.
      expect(spans.last.text, 'や');
      expect(spans.last.end - spans.last.start, const Duration(milliseconds: 1800));
    });

    test('words with brackets in them stay whole', () {
      final lines = LyricsService.parseLrc(NeteaseLyrics.yrcToEnhancedLrc(yrc));
      expect([for (final w in lines.last.words) w.text], ['(Cover ', 'us)']);
    });

    test('plain NetEase lyrics lose their credit lines', () {
      const lrc = '[00:00.00] 作词 : ZAQ\n[00:00.50] 作曲 : ZAQ\n[00:12.00] 忘れてやらない';
      final lines = LyricsService.parseLrc(NeteaseLyrics.dropCredits(lrc));
      expect([for (final l in lines) l.text], ['忘れてやらない']);
    });
  });

  group('picking the NetEase song', () {
    const title = '忘れてやらない - Never forget - kessoku band';
    const length = Duration(seconds: 222);

    test('the release whose length matches, not a longer cut', () {
      final pick = NeteaseLyrics.pickSong(
        const [
          NeteaseSong(id: 1, name: '忘れてやらない', artists: '結束バンド',
              duration: Duration(seconds: 236)),
          NeteaseSong(id: 2, name: '忘れてやらない', artists: '結束バンド',
              duration: Duration(seconds: 223)),
        ],
        title,
        duration: length,
      );
      expect(pick?.id, 2);
    });

    test('a different song is never taken', () {
      final pick = NeteaseLyrics.pickSong(
        const [
          NeteaseSong(id: 3, name: '瞳の中にいてください', artists: '春野杉卉',
              duration: Duration(seconds: 168)),
        ],
        '碧い瞳の中に - in your blue eyes - Ave Mujica',
        duration: const Duration(seconds: 250),
      );
      expect(pick, isNull);
    });
  });

  test('the app mark in saved plain lyrics is not shown as a line', () {
    final lines = LyricsService.parseLrc(
      'first line\nsecond line\n${LyricsService.wordTimingCheckedMark}',
    );
    expect([for (final l in lines) l.text], ['first line', 'second line']);
  });
}
