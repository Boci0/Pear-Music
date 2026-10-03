import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/lyrics_service.dart';

const _raw = '''
[offset: 200]
[00:10.00]First line here
[00:14.00]<00:14.000>Word <00:14.400>timed <00:14.800>line<00:15.200>
[00:18.00][00:30.00]Sung twice
[00:22.00]Last line
[pear:source:lrclib-manual]
''';

Song _song() => Song(
      id: 'nudge_song',
      title: 'Nudge',
      fileName: 'n.m4a',
      size: 1,
      checksum: 'n',
      addedAt: DateTime(2026),
    );

LyricLine _line(List<LyricLine> lines, String text, {int? atMs}) =>
    lines.firstWhere((l) =>
        l.text == text && (atMs == null || l.timestamp.inMilliseconds == atMs));

void main() {
  tearDown(LyricsService.clearMemoryCache);

  test('moves only the chosen line and leaves the rest untouched', () {
    final lines = LyricsService.parseLrc(_raw);
    final out = LyricsService.nudgeLineInRaw(
        _raw, _line(lines, 'First line here'), 300)!;
    final after = LyricsService.parseLrc(out);
    expect(_line(after, 'First line here').timestamp,
        const Duration(milliseconds: 10500)); // 10.0 + 0.2 offset + 0.3
    expect(_line(after, 'Last line').timestamp,
        const Duration(milliseconds: 22200));
    expect(LyricsService.extractOffsetMs(out), 200);
    expect(out, contains('[pear:source:lrclib-manual]'));
  });

  test('word timing moves with its line', () {
    final lines = LyricsService.parseLrc(_raw);
    final before = _line(lines, 'Word timed line');
    final out = LyricsService.nudgeLineInRaw(_raw, before, -400)!;
    final after = _line(LyricsService.parseLrc(out), 'Word timed line');
    expect(after.timestamp, before.timestamp - const Duration(milliseconds: 400));
    expect(after.words.length, 3);
    for (var i = 0; i < 3; i++) {
      expect(after.words[i].start,
          before.words[i].start - const Duration(milliseconds: 400));
    }
    expect(after.words.last.end,
        before.words.last.end! - const Duration(milliseconds: 400));
  });

  test('a repeated line moves one time only', () {
    final lines = LyricsService.parseLrc(_raw);
    final second = _line(lines, 'Sung twice', atMs: 30200);
    final out = LyricsService.nudgeLineInRaw(_raw, second, 500)!;
    final after = LyricsService.parseLrc(out)
        .where((l) => l.text == 'Sung twice')
        .map((l) => l.timestamp.inMilliseconds)
        .toList();
    expect(after, [18200, 30700]);
  });

  test('never moves a line before the start of the song', () {
    final lines = LyricsService.parseLrc(_raw);
    final out = LyricsService.nudgeLineInRaw(
        _raw, _line(lines, 'First line here'), -60000)!;
    expect(_line(LyricsService.parseLrc(out), 'First line here').timestamp,
        const Duration(milliseconds: 200)); // raw tag 0 plus the offset
  });

  test('a line that is not in the lyrics changes nothing', () {
    const ghost = LyricLine(
        timestamp: Duration(seconds: 5), text: 'Not in the file');
    expect(LyricsService.nudgeLineInRaw(_raw, ghost, 100), isNull);
  });

  test('nudgeLine saves the moved lyrics for the song', () async {
    LyricsService.setLyricsForTesting('nudge_song', _raw);
    final lines = LyricsService.parseLrc(_raw);
    final result = await LyricsService.nudgeLine(
        _song(), _line(lines, 'Last line'), 250);
    expect(result, isNotNull);
    expect(_line(result!, 'Last line').timestamp,
        const Duration(milliseconds: 22450));
    final raw = (await LyricsService.getRawLrc(_song()))!;
    expect(_line(LyricsService.parseLrc(raw), 'Last line').timestamp,
        const Duration(milliseconds: 22450));
  });
}
