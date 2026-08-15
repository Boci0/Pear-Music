import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerService queue updates and context isolation', () {
    final songA = Song(
      id: 'a',
      title: 'Alpha',
      fileName: 'a.mp3',
      size: 100,
      checksum: 'chk_a',
      addedAt: DateTime(2026, 1, 1),
    );
    final songB = Song(
      id: 'b',
      title: 'Beta',
      fileName: 'b.mp3',
      size: 200,
      checksum: 'chk_b',
      addedAt: DateTime(2026, 1, 2),
    );
    final songC = Song(
      id: 'c',
      title: 'Gamma',
      fileName: 'c.mp3',
      size: 300,
      checksum: 'chk_c',
      addedAt: DateTime(2026, 1, 3),
    );

    late LibraryService library;
    late PlayerService player;

    setUp(() {
      library = LibraryService();
      player = PlayerService(library);
    });

    test('updateQueue updates queue and preserves current song index', () {
      // Initial queue: [A, B, C]
      player.updateQueue([songA, songB, songC], sourceId: 'library', sourceTitle: 'Library');
      expect(player.queue.length, 3);
      expect(player.queue[0].id, 'a');
      expect(player.queueSourceId, 'library');

      // Set currentSong to songB
      player.currentSong = songB;
      player.updateQueue([songC, songB, songA]);

      // Queue is now [C, B, A], current song is B, index should be 1
      expect(player.queue[0].id, 'c');
      expect(player.queue[1].id, 'b');
      expect(player.queue[2].id, 'a');
      expect(player.queueIndex, 1);
    });

    test('updateQueue prepends currentSong if filtered out by favorites', () {
      player.currentSong = songA;
      
      // Filter contains only [B, C]
      player.updateQueue([songB, songC], sourceId: 'favorites', sourceTitle: 'Favorites');

      // Current song A should remain in queue at index 0
      expect(player.queue.first.id, 'a');
      expect(player.queueIndex, 0);
      expect(player.queue.length, 3);
      expect(player.queueSourceId, 'favorites');
    });

    test('Playlist queue source is isolated and preserved', () {
      // User starts a playlist
      player.updateQueue(
        [songB, songA],
        sourceId: 'playlist:pl_1',
        sourceTitle: 'My Playlist',
      );
      player.currentSong = songB;

      expect(player.queueSourceId, 'playlist:pl_1');
      expect(player.queue.length, 2);
      expect(player.queue[0].id, 'b');
      expect(player.queue[1].id, 'a');

      // When checking queue source, it is clearly identified as a playlist
      expect(player.queueSourceId?.startsWith('playlist:'), isTrue);
    });
  });
}
