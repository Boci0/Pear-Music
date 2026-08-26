import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/innertube_player_service.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InnertubePlayerService Tests', () {
    test('hasCachedStream returns false for empty cache', () {
      expect(InnertubePlayerService.hasCachedStream('non_existent'), isFalse);
    });

    test('InnertubeAudioStream model fields check', () {
      const stream = InnertubeAudioStream(
        url: 'https://example.com/audio.m4a',
        itag: 140,
        mimeType: 'audio/mp4; codecs="mp4a.40.2"',
        bitrate: 128000,
        contentLength: 4000000,
        container: 'm4a',
      );
      expect(stream.url, 'https://example.com/audio.m4a');
      expect(stream.itag, 140);
      expect(stream.container, 'm4a');
      expect(stream.bitrate, 128000);
    });
  });

  group('StreamCacheManager Tests', () {
    test('isStreamCachedSync returns false for unseen video IDs', () {
      expect(StreamCacheManager.isStreamCachedSync('unseen_12345'), isFalse);
    });

    test('cache quota constraints are bounded', () {
      expect(StreamCacheManager.maxCacheBytes, equals(60 * 1024 * 1024));
      expect(StreamCacheManager.maxTrackCount, equals(15));
    });
  });
}
