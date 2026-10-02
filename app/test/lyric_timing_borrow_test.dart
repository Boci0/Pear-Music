import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/lyric_timing_borrow.dart';
import 'package:peerm_app/services/lyrics_service.dart';
import 'package:peerm_app/services/netease_lyrics.dart';

const _user = '''
[offset: 150]
[00:10.00]Sit down be humble
[00:14.00]Hold up, little bit longer
[00:18.00]Nothing but words
[00:22.00]Keep it moving
''';

String _timed(List<int> lineStartsMs, List<String> texts) {
  final b = StringBuffer();
  for (var i = 0; i < texts.length; i++) {
    final words = texts[i].split(' ');
    final start = lineStartsMs[i];
    b.write('[${_s(start)}]');
    for (var w = 0; w < words.length; w++) {
      b.write('<${_s(start + w * 400)}>${words[w]}${w < words.length - 1 ? ' ' : ''}');
    }
    b.writeln('<${_s(start + words.length * 400)}>');
  }
  return b.toString();
}

String _s(int ms) =>
    '${(ms ~/ 60000).toString().padLeft(2, '0')}:'
    '${((ms % 60000) ~/ 1000).toString().padLeft(2, '0')}.'
    '${(ms % 1000).toString().padLeft(3, '0')}';

Song _song() => Song(
      id: 'borrow_song',
      title: 'HUMBLE. - Kendrick Lamar',
      fileName: 'a.m4a',
      size: 1,
      checksum: 'c',
      addedAt: DateTime(2026),
    );

void main() {
  const texts = [
    'Sit down be humble',
    'Hold up little bit longer',
    'Nothing but words',
    'Keep it moving',
  ];

  test('every line matching gives word timing and keeps text and offset', () {
    // NetEase lines start up to 1.2 s from the hand-picked ones.
    final merged = LyricTimingBorrow.merge(
      _user,
      _timed([10500, 14000, 18900, 22000], texts),
    )!;
    expect(LyricsService.extractOffsetMs(merged), 150);
    final lines = LyricsService.parseLrc(merged);
    expect(lines.map((l) => l.text).toList(), [
      'Sit down be humble',
      'Hold up, little bit longer',
      'Nothing but words',
      'Keep it moving',
    ]);
    expect(lines.every((l) => l.words.isNotEmpty), isTrue);
    // Line times are the user's (plus the offset), not NetEase's.
    expect(lines.first.timestamp, const Duration(milliseconds: 10150));
    expect(lines.first.words.first.start, const Duration(milliseconds: 10150));
    expect(lines.first.words.map((w) => w.text).join(), 'Sit down be humble');
    expect(lines.first.words.length, 4);
  });

  test('a minority of unmatched lines keep their own timing', () {
    final merged = LyricTimingBorrow.merge(
      '$_user[00:26.00]Something nobody sings\n[00:30.00]Another\n',
      _timed([10000, 14000, 18000, 22000], texts),
    );
    // 4 of 6 lines is below the share needed.
    expect(merged, isNull);

    final fiveOfSix = LyricTimingBorrow.merge(
      '$_user[00:26.00]Something nobody sings\n',
      _timed([10000, 14000, 18000, 22000], texts),
    )!;
    final lines = LyricsService.parseLrc(fiveOfSix);
    expect(lines.length, 5);
    expect(lines.last.words, isEmpty);
    expect(lines.last.text, 'Something nobody sings');
    expect(lines.where((l) => l.words.isNotEmpty).length, 4);
  });

  test('timing that is far off or for other words is no fit', () {
    expect(
      LyricTimingBorrow.merge(
        _user,
        _timed([40000, 44000, 48000, 52000], texts),
      ),
      isNull,
    );
    expect(
      LyricTimingBorrow.merge(
        _user,
        _timed([10000, 14000, 18000, 22000],
            ['la la la la', 'na na na na', 'oh oh oh oh', 'hey hey hey']),
      ),
      isNull,
    );
  });

  group('tryNeteaseWordTiming', () {
    tearDown(() {
      LyricsService.neteaseWordTimingForTesting = null;
      LyricsService.clearMemoryCache();
    });

    test('borrows timing, keeping the hand-picked source and text', () async {
      LyricsService.setLyricsForTesting(
        'borrow_song',
        '$_user[pear:word-timing-checked]\n[pear:source:lrclib-manual]',
      );
      LyricsService.neteaseWordTimingForTesting = (s, {duration}) async =>
          NeteaseResult(_timed([10000, 14000, 18000, 22000], texts),
              hasWordTiming: true);

      final result = await LyricsService.tryNeteaseWordTiming(
        _song(),
        duration: const Duration(minutes: 2, seconds: 57),
      );
      expect(result, isNotNull);
      expect(result!.every((l) => l.words.isNotEmpty), isTrue);
      final raw = (await LyricsService.getRawLrc(_song()))!;
      expect(LyricsService.sourceOf(raw), 'lrclib-manual');
      expect(raw, contains(LyricsService.timingBorrowedMark));
      expect(LyricsService.extractOffsetMs(raw), 150);
    });

    test('no fit leaves the lyrics untouched', () async {
      final before = '$_user[pear:source:lrclib-manual]';
      LyricsService.setLyricsForTesting('borrow_song', before);
      LyricsService.neteaseWordTimingForTesting = (s, {duration}) async =>
          NeteaseResult(
              _timed([60000, 64000, 68000, 72000], texts),
              hasWordTiming: true);

      final result = await LyricsService.tryNeteaseWordTiming(
        _song(),
        duration: const Duration(minutes: 3),
      );
      expect(result, isNull);
      expect(await LyricsService.getRawLrc(_song()), before);
    });
  });
}
