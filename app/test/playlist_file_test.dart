import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/playlist_file.dart';

void main() {
  group('PlaylistFile.parse', () {
    test('reads the name, titles and targets in order', () {
      final parsed = PlaylistFile.parse(
        '#EXTM3U\n#PLAYLIST:Road trip\n'
        '#EXTINF:215,Artist - First\nhttps://www.youtube.com/watch?v=abcdefghijk\n'
        '\n'
        'C:\\Music\\second.mp3\n'
        '#EXTINF:-1,Third\n#EXTVLCOPT:foo\nthird.flac\n',
      );
      expect(parsed.name, 'Road trip');
      expect(parsed.entries, [
        (
          title: 'Artist - First',
          target: 'https://www.youtube.com/watch?v=abcdefghijk',
        ),
        (title: '', target: 'C:\\Music\\second.mp3'),
        (title: 'Third', target: 'third.flac'),
      ]);
    });

    test('a byte order mark does not turn the header into a track', () {
      final parsed = PlaylistFile.parse('\uFEFF#EXTM3U\r\nsong.mp3\r\n');
      expect(parsed.entries, [(title: '', target: 'song.mp3')]);
    });

    test('an #EXTINF without a following path is dropped', () {
      final parsed = PlaylistFile.parse('#EXTM3U\n#EXTINF:-1,Orphan\n');
      expect(parsed.entries, isEmpty);
      expect(parsed.name, isNull);
    });
  });

  group('PlaylistFile.decode', () {
    test('strips the UTF-8 byte order mark', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('#EXTM3U')];
      expect(PlaylistFile.decode(bytes), '#EXTM3U');
    });

    test('falls back to Latin-1 for non UTF-8 files', () {
      final bytes = latin1.encode('#EXTINF:-1,Beyoncé\nb.mp3');
      final parsed = PlaylistFile.parse(PlaylistFile.decode(bytes));
      expect(parsed.entries.single.title, 'Beyoncé');
    });
  });

  test('build round-trips through parse and keeps entries on one line', () {
    final content = PlaylistFile.build('Mix\nTape', [
      (title: 'Line\nbreak', target: 'https://youtu.be/abcdefghijk'),
      (title: 'Local', target: 'local.mp3'),
    ]);
    final parsed = PlaylistFile.parse(content);
    expect(parsed.name, 'Mix Tape');
    expect(parsed.entries, [
      (title: 'Line break', target: 'https://youtu.be/abcdefghijk'),
      (title: 'Local', target: 'local.mp3'),
    ]);
  });

  test('safeFileName replaces characters Windows rejects', () {
    expect(PlaylistFile.safeFileName('a/b:c?'), 'a_b_c_.m3u8');
    expect(PlaylistFile.safeFileName('   '), 'playlist.m3u8');
  });
}
