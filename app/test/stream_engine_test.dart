import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StreamCacheManager Tests', () {
    test('isStreamCachedSync returns false for unseen video IDs', () {
      expect(StreamCacheManager.isStreamCachedSync('unseen_12345'), isFalse);
    });

    test('cache quota constraints are bounded', () {
      expect(StreamCacheManager.maxCacheBytes, equals(500 * 1024 * 1024));
      expect(StreamCacheManager.maxTrackCount, equals(100));
    });

    test('clearCache resets in-memory tracking', () async {
      await StreamCacheManager.clearCache();
      final stats = StreamCacheManager.getCacheStats();
      expect(stats.trackCount, equals(0));
      expect(stats.totalBytes, equals(0));
    });

    test('audioFormatArg provides platform-adaptive selectors for Desktop (Opus) and Android (AAC)', () {
      expect(StreamCacheManager.desktopAudioFormatArg, contains('acodec=opus'));
      expect(StreamCacheManager.desktopAudioFormatArg, contains('abr<=130'));
      expect(StreamCacheManager.androidAudioFormatArg, contains('140'));
      expect(StreamCacheManager.androidAudioFormatArg, contains('ext=m4a'));
    });
  });
}

