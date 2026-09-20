import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_profile.dart';

Song _song({
  required String id,
  required String title,
  required String fileName,
}) =>
    Song(
      id: id,
      title: title,
      fileName: fileName,
      size: 1000,
      checksum: id,
      addedAt: DateTime(2026, 1, 1),
    );

void main() {
  group('LibraryProfile.build', () {
    test('exports link-added songs and skips local-only songs', () {
      final content = LibraryProfile.build([
        _song(id: 'a', title: 'Song One', fileName: 'a [dQw4w9WgXcQ].webm'),
        _song(id: 'b', title: 'From Disk', fileName: 'b.mp3'),
      ]);
      expect(content, isNotNull);
      expect(content, contains('#EXTM3U'));
      expect(content, contains('#EXTINF:-1,Song One'));
      expect(
        content,
        contains('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
      );
      expect(content, isNot(contains('From Disk')));
    });

    test('collapses duplicate video IDs, keeping the first entry', () {
      final content = LibraryProfile.build([
        _song(id: 'a', title: 'First', fileName: 'a [dQw4w9WgXcQ].webm'),
        _song(id: 'b', title: 'Second Copy', fileName: 'b [dQw4w9WgXcQ].m4a'),
      ]);
      expect(content, isNotNull);
      expect(
        RegExp(r'watch\?v=dQw4w9WgXcQ').allMatches(content!).length,
        1,
      );
      expect(content, contains('First'));
      expect(content, isNot(contains('Second Copy')));
    });

    test('returns null when nothing is link-based', () {
      expect(
        LibraryProfile.build([
          _song(id: 'a', title: 'Local', fileName: 'a.mp3'),
        ]),
        isNull,
      );
      expect(LibraryProfile.build(const []), isNull);
    });

    test('marks favorited entries with a #FAVORITE line', () {
      final content = LibraryProfile.build(
        [
          _song(id: 'a', title: 'Hearted', fileName: 'a [dQw4w9WgXcQ].webm'),
          _song(id: 'b', title: 'Plain', fileName: 'b [kJQP7kiw5Fk].m4a'),
        ],
        favoriteVideoIds: {'dQw4w9WgXcQ'},
      );
      expect(content, isNotNull);
      expect(content, contains('#FAVORITE dQw4w9WgXcQ'));
      expect(content, isNot(contains('#FAVORITE kJQP7kiw5Fk')));
    });

    test('writes no #FAVORITE lines when nothing is favorited', () {
      final content = LibraryProfile.build([
        _song(id: 'a', title: 'One', fileName: 'a [dQw4w9WgXcQ].webm'),
      ]);
      expect(content, isNotNull);
      expect(content, isNot(contains('#FAVORITE')));
    });

    test('appends an online favorites section for stream favorites', () {
      final content = LibraryProfile.build(
        const [],
        onlineFavorites: const [
          ProfileOnlineFavorite(
            videoId: 'kJQP7kiw5Fk',
            title: 'Stream Only',
            artwork: 'https://example.com/art.jpg',
          ),
        ],
      );
      expect(content, isNotNull);
      expect(content, contains('#PEARMUSIC-ONLINE-FAVORITES'));
      expect(content, contains('Stream Only'));
      expect(content, contains('#PEARMUSIC-ART https://example.com/art.jpg'));
      expect(content, isNot(contains('#FAVORITE')));
    });
  });

  group('LibraryProfile.parse', () {
    test('reads entries in order and ignores local paths and comments', () {
      const content = '''
#EXTM3U
#PEARMUSIC-LIBRARY-PROFILE
#PLAYLIST:Pear Music Library
#EXTINF:-1,Song One
https://www.youtube.com/watch?v=dQw4w9WgXcQ
#EXTINF:-1,Local File On Sender
just/a/local/file.mp3
#EXTINF:-1,Song Two
https://www.youtube.com/watch?v=kJQP7kiw5Fk
''';
      final entries = LibraryProfile.parse(content);
      expect(
        entries.map((e) => e.videoId).toList(),
        ['dQw4w9WgXcQ', 'kJQP7kiw5Fk'],
      );
      expect(entries.first.title, 'Song One');
      expect(entries.last.title, 'Song Two');
    });

    test('deduplicates repeated IDs across differently written links', () {
      const content = '''
#EXTINF:-1,Short Link
https://youtu.be/dQw4w9WgXcQ
#EXTINF:-1,Long Link
https://www.youtube.com/watch?v=dQw4w9WgXcQ
''';
      final entries = LibraryProfile.parse(content);
      expect(entries.length, 1);
      expect(entries.first.videoId, 'dQw4w9WgXcQ');
    });

    test('round-trips through build', () {
      final built = LibraryProfile.build([
        _song(id: 'a', title: 'One', fileName: 'a [dQw4w9WgXcQ].webm'),
        _song(id: 'b', title: 'Two', fileName: 'b [kJQP7kiw5Fk].m4a'),
      ]);
      final parsed = LibraryProfile.parse(built!);
      expect(
        parsed.map((e) => e.videoId).toList(),
        ['dQw4w9WgXcQ', 'kJQP7kiw5Fk'],
      );
      expect(parsed.map((e) => e.title).toList(), ['One', 'Two']);
    });

    test('reads favorite markers and ignores malformed ones', () {
      const content = '''
#EXTM3U
#EXTINF:-1,Song One
https://www.youtube.com/watch?v=dQw4w9WgXcQ
#FAVORITE dQw4w9WgXcQ
#EXTINF:-1,Song Two
https://www.youtube.com/watch?v=kJQP7kiw5Fk
#FAVORITE not-a-video-id
''';
      final favorites = LibraryProfile.parseFavoriteIds(content);
      expect(favorites, {'dQw4w9WgXcQ'});
    });

    test('round-trips favorites through build and parse', () {
      final built = LibraryProfile.build(
        [
          _song(id: 'a', title: 'One', fileName: 'a [dQw4w9WgXcQ].webm'),
          _song(id: 'b', title: 'Two', fileName: 'b [kJQP7kiw5Fk].m4a'),
        ],
        favoriteVideoIds: {'kJQP7kiw5Fk'},
      );
      expect(LibraryProfile.parseFavoriteIds(built!), {'kJQP7kiw5Fk'});
      // The favorites comment does not disturb the entry list.
      final parsed = LibraryProfile.parse(built);
      expect(
        parsed.map((e) => e.videoId).toList(),
        ['dQw4w9WgXcQ', 'kJQP7kiw5Fk'],
      );
    });

    test('keeps online favorites out of the downloadable entry list', () {
      final built = LibraryProfile.build(
        [
          _song(id: 'a', title: 'Library Song', fileName: 'a [dQw4w9WgXcQ].webm'),
        ],
        onlineFavorites: const [
          ProfileOnlineFavorite(videoId: 'kJQP7kiw5Fk', title: 'Stream Only'),
        ],
      )!;
      expect(
        LibraryProfile.parse(built).map((e) => e.videoId).toList(),
        ['dQw4w9WgXcQ'],
      );
      final online = LibraryProfile.parseOnlineFavorites(built);
      expect(online.length, 1);
      expect(online.first.videoId, 'kJQP7kiw5Fk');
      expect(online.first.title, 'Stream Only');
      expect(online.first.artwork, isNull);
    });

    test('parseOnlineFavorites deduplicates and skips malformed entries', () {
      const content = '''
#EXTM3U
#EXTINF:-1,Library
https://www.youtube.com/watch?v=dQw4w9WgXcQ
#PEARMUSIC-ONLINE-FAVORITES
#EXTINF:-1,One
#PEARMUSIC-ART https://example.com/one.jpg
https://www.youtube.com/watch?v=kJQP7kiw5Fk
#EXTINF:-1,One Again
https://www.youtube.com/watch?v=kJQP7kiw5Fk
#EXTINF:-1,Bad
not a link
''';
      final online = LibraryProfile.parseOnlineFavorites(content);
      expect(online.length, 1);
      expect(online.first.videoId, 'kJQP7kiw5Fk');
      expect(online.first.title, 'One');
      expect(online.first.artwork, 'https://example.com/one.jpg');
    });
  });
}
