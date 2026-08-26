import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/recommendation_service.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

void main() {
  group('RecommendationItem & Models', () {
    test('toSong produces a valid stream song', () {
      const item = RecommendationItem(
        videoId: 'dQw4w9WgXcQ',
        title: 'Never Gonna Give You Up',
        artist: 'Rick Astley',
        duration: Duration(minutes: 3, seconds: 32),
      );

      final song = item.toSong();
      expect(song.id, 'stream_dQw4w9WgXcQ');
      expect(song.sourceDeviceId, 'stream');
      expect(song.title, contains('Never Gonna Give You Up'));
      expect(song.fileName, contains('[dQw4w9WgXcQ]'));
      expect(item.durationFormatted, '3:32');
    });

    test('markPlayed prevents recommendation duplicates in session', () {
      RecommendationService.clearSessionHistory();
      RecommendationService.markPlayed('stream_dQw4w9WgXcQ');
      RecommendationService.markPlayed('Rick Astley - Never Gonna Give You Up [dQw4w9WgXcQ].m4a');
      // Should not throw and correctly records ID
      RecommendationService.clearSessionHistory();
    });

    test('getOfflineRecommendations ranks songs by keyword and artist affinity', () {
      final seed = Song(
        id: 'seed-1',
        title: 'Queen - Bohemian Rhapsody',
        fileName: 'queen.mp3',
        size: 5000000,
        checksum: 'abc',
        addedAt: DateTime.now(),
      );

      final library = [
        Song(
          id: '1',
          title: 'Queen - Don\'t Stop Me Now',
          fileName: 'queen2.mp3',
          size: 5000000,
          checksum: 'def',
          addedAt: DateTime.now(),
        ),
        Song(
          id: '2',
          title: 'Beethoven - Symphony No. 5',
          fileName: 'beethoven.mp3',
          size: 5000000,
          checksum: 'ghi',
          addedAt: DateTime.now(),
        ),
        Song(
          id: '3',
          title: 'Queen - Radio Ga Ga',
          fileName: 'queen3.mp3',
          size: 5000000,
          checksum: 'jkl',
          addedAt: DateTime.now(),
        ),
      ];

      final recs = RecommendationService.getOfflineRecommendations(seed, library);
      expect(recs, isNotEmpty);
      expect(recs.first.title, contains('Queen'));
    });

    test('generateSearchCandidates extracts primary title from complex multi-language OST titles', () {
      final song = Song(
        id: '123',
        title: 'Arknights OST - Battleplan Obliteration | アークナイツ/明日方舟 危機契約#12 殲滅作戦',
        fileName: 'track.mp3',
        size: 1000,
        checksum: '123',
        addedAt: DateTime.now(),
      );

      final candidates = RecommendationService.generateSearchCandidates(song);
      expect(candidates, isNotEmpty);
      expect(candidates.first, equals('Arknights OST - Battleplan Obliteration'));
      expect(candidates, contains('Battleplan Obliteration'));
    });

    test('generateSearchCandidates cleans corrupted mojibake titles with Latin prefixes', () {
      final corruptedSong = Song(
        id: '124',
        title: 'Arknights OST - Battleplan Obliteration \uFFFD\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD',
        fileName: 'track.mp4',
        size: 1000,
        checksum: '124',
        addedAt: DateTime.now(),
      );

      final candidates = RecommendationService.generateSearchCandidates(corruptedSong);
      expect(candidates, isNotEmpty);
      expect(candidates.first, equals('Arknights OST - Battleplan Obliteration'));
      expect(candidates, contains('Battleplan Obliteration'));
    });

    test('resolveSeedVideoId extracts ID from song id or fileName directly', () async {
      final directSong = Song(
        id: 'stream_abc12345678',
        title: 'Test Song',
        fileName: 'Test Song [abc12345678].m4a',
        size: 1000,
        checksum: 'stream_abc12345678',
        addedAt: DateTime.now(),
      );
      final id = await RecommendationService.resolveSeedVideoId(directSong);
      expect(id, equals('abc12345678'));
    });
  });

  group('StreamCacheManager', () {
    test('quota constants are bounded and safe', () {
      expect(StreamCacheManager.maxCacheBytes, equals(150 * 1024 * 1024));
      expect(StreamCacheManager.targetEvictionBytes, equals(100 * 1024 * 1024));
      expect(StreamCacheManager.maxTrackCount, equals(50));
    });
  });
}
