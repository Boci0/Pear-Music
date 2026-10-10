import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/recommendation_service.dart';
import 'package:peerm_app/services/youtube_search_service.dart';

/// A YouTube Music search row, shaped like the real response.
Map<String, dynamic> _row(String videoId, List<String> subtitle,
        {bool live = false}) =>
    {
      'musicResponsiveListItemRenderer': {
        'flexColumns': [
          {
            'musicResponsiveListItemFlexColumnRenderer': {
              'text': {
                'runs': [
                  {'text': 'Title $videoId'},
                ],
              },
            },
          },
          {
            'musicResponsiveListItemFlexColumnRenderer': {
              'text': {
                'runs': [
                  for (final s in subtitle) {'text': s},
                ],
              },
            },
          },
        ],
        'playlistItemData': {'videoId': videoId},
        if (live)
          'badges': [
            {
              'liveBadgeRenderer': {
                'label': {'runs': [{'text': 'LIVE'}]},
              },
            },
          ],
      },
    };

void main() {
  test('a YouTube Music row with a live badge is marked live', () {
    final items = RecommendationService.parseSongRowsForTesting([
      _row('livevideo01', ['Video', ' • ', 'Lofi Girl', ' • ', '14M views'],
          live: true),
      _row('songvideo01', ['Song', ' • ', 'Artist', ' • ', '3:12']),
    ]);
    expect(items.map((i) => i.isLive), [true, false]);
    expect(items.first.duration, isNull);
    expect(items.last.duration, const Duration(minutes: 3, seconds: 12));
  });

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
