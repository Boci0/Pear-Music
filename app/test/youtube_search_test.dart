import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/youtube_search_service.dart';

void main() {
  group('YouTubeSearchResult', () {
    test('formats duration correctly', () {
      const item1 = YouTubeSearchResult(
        videoId: 'abc12345',
        title: 'Test Song',
        author: 'Test Artist',
        duration: Duration(minutes: 3, seconds: 45),
        thumbnailUrl: 'https://img.youtube.com/vi/abc12345/0.jpg',
      );

      expect(item1.durationFormatted, '3:45');
      expect(item1.url, 'https://www.youtube.com/watch?v=abc12345');

      const item2 = YouTubeSearchResult(
        videoId: 'def67890',
        title: 'Short Clip',
        author: 'Artist',
        duration: Duration(seconds: 9),
      );
      expect(item2.durationFormatted, '0:09');

      const item3 = YouTubeSearchResult(
        videoId: 'xyz',
        title: 'Live Stream',
        author: 'Channel',
        duration: null,
      );
      expect(item3.durationFormatted, '--:--');
    });

    test('search returns empty list for empty/whitespace query', () async {
      final res1 = await YouTubeSearchService.search('');
      expect(res1, isEmpty);

      final res2 = await YouTubeSearchService.search('   ');
      expect(res2, isEmpty);
    });
  });
}
