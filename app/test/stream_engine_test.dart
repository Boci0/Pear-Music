import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/innertube_player_service.dart';
import 'package:peerm_app/services/stream_proxy_service.dart';

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

  group('StreamProxyService Tests', () {
    tearDownAll(() async {
      await StreamProxyService.stop();
    });

    test('getStreamProxyUri generates a valid loopback URI', () async {
      final uri = await StreamProxyService.getStreamProxyUri('dQw4w9WgXcQ');
      expect(uri, isNotNull);
      expect(uri!.scheme, 'http');
      expect(uri.host, '127.0.0.1');
      expect(uri.path, '/stream/dQw4w9WgXcQ');
      expect(uri.port, isPositive);
    });
  });
}
