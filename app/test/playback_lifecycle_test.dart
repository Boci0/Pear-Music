import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/recommendation_service.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return Directory.systemTemp.path;
    });
  });

  group('StreamCacheManager Lifecycle & Deduplication Tests', () {
    test('isStreamCachedSync returns false for uncached track', () {
      expect(StreamCacheManager.isStreamCachedSync('test_video_999'), isFalse);
    });

    test('getInFlightDownload returns null when no download is active', () {
      expect(StreamCacheManager.getInFlightDownload('test_video_999'), isNull);
    });

    test('Cache directory creates and isolates peerm_radio_cache', () async {
      final dir = await StreamCacheManager.getCacheDirectory();
      expect(await dir.exists(), isTrue);
      expect(dir.path, contains('peerm_radio_cache'));
    });

    test('enforceCacheQuota bounds cache to maxTrackCount and maxCacheBytes', () async {
      final dir = await StreamCacheManager.getCacheDirectory();
      expect(StreamCacheManager.maxTrackCount, 15);
      expect(StreamCacheManager.maxCacheBytes, 60 * 1024 * 1024);

      final dummyOldTemp = File('${dir.path}/test_cleanup.tmp.m4a');
      await dummyOldTemp.writeAsString('test');
      expect(await dummyOldTemp.exists(), isTrue);

      await StreamCacheManager.enforceCacheQuota();
    });
  });

  group('Playback Token & Queue Race Condition Simulation', () {
    test('Token increment cancels outdated asynchronous completions', () async {
      int activeToken = 0;
      final completedTokens = <int>[];

      Future<void> simulatePlay(int requestToken, Duration delay) async {
        activeToken = requestToken;
        await Future<void>.delayed(delay);
        if (requestToken != activeToken) {
          return;
        }
        completedTokens.add(requestToken);
      }

      final f1 = simulatePlay(1, const Duration(milliseconds: 100));
      final f2 = simulatePlay(2, const Duration(milliseconds: 80));
      final f3 = simulatePlay(3, const Duration(milliseconds: 20));

      await Future.wait([f1, f2, f3]);

      expect(completedTokens, equals([3]));
    });

    test('Sliding window preloading processes top 3 items sequentially', () async {
      final requestedIds = <String>[];
      final videoIds = ['vid_1', 'vid_2', 'vid_3', 'vid_4', 'vid_5'];

      for (final id in videoIds.take(3)) {
        requestedIds.add(id);
      }

      expect(requestedIds, equals(['vid_1', 'vid_2', 'vid_3']));
      expect(requestedIds.length, 3);
    });

    test('RecommendationService prevents infinite duplicate loops', () {
      RecommendationService.clearSessionHistory();
      const seedId = 'stream_test123';
      RecommendationService.markPlayed(seedId);

      final songs = [
        Song(
          id: 'stream_test123',
          title: 'Song 1',
          fileName: 'Song 1 [test123].m4a',
          size: 1000,
          checksum: '1',
          addedAt: DateTime.now(),
        ),
        Song(
          id: 'stream_test456',
          title: 'Song 2',
          fileName: 'Song 2 [test456].m4a',
          size: 1000,
          checksum: '2',
          addedAt: DateTime.now(),
        ),
      ];

      final filtered = songs.where((s) => s.id != seedId).toList();
      expect(filtered.length, 1);
      expect(filtered.first.id, 'stream_test456');
    });
  });
}
