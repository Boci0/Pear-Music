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

  test('the live filter keeps only rows that are live now, once each', () {
    Map<String, dynamic> row(String id, {bool live = true}) => {
          'videoRenderer': {
            'videoId': id,
            'title': {
              'runs': [
                {'text': 'Lofi '},
                {'text': 'Radio $id'},
              ],
            },
            'ownerText': {
              'runs': [
                {'text': 'Some Channel'},
              ],
            },
            'thumbnail': {
              'thumbnails': [
                {'url': 'https://i/small.jpg'},
                {'url': 'https://i/$id.jpg'},
              ],
            },
            'badges': [
              if (live)
                {
                  'metadataBadgeRenderer': {'style': 'BADGE_STYLE_TYPE_LIVE_NOW'},
                },
            ],
          },
        };

    final response = {
      'contents': {
        'twoColumnSearchResultsRenderer': {
          'primaryContents': {
            'sectionListRenderer': {
              'contents': [
                {
                  'itemSectionRenderer': {
                    'contents': [
                      row('a1'),
                      row('b2', live: false),
                      row('a1'),
                      {'channelRenderer': {}},
                      row('c3'),
                    ],
                  },
                },
              ],
            },
          },
        },
      },
    };

    final items = YouTubeSearchService.parseLiveResults(response);
    expect(items.map((i) => i.videoId), ['a1', 'c3']);
    expect(items.every((i) => i.isLive), isTrue);
    expect(items.first.title, 'Lofi Radio a1');
    expect(items.first.author, 'Some Channel');
    expect(items.first.thumbnailUrl, 'https://i/a1.jpg');
    expect(YouTubeSearchService.parseLiveResults(null), isEmpty);
  });

  test('live streams are mixed in after the first songs, once each', () {
    YouTubeSearchResult song(String id) =>
        YouTubeSearchResult(videoId: id, title: id, author: 'a');
    YouTubeSearchResult live(String id) =>
        YouTubeSearchResult(videoId: id, title: id, author: 'a', isLive: true);

    final mixed = YouTubeSearchService.mixLive(
      [song('s1'), song('s2'), song('s3'), song('s4'), song('dup')],
      [live('l1'), live('dup')],
    );
    expect(
      mixed.map((r) => r.videoId),
      ['s1', 's2', 's3', 'l1', 'dup', 's4'],
    );
    expect(mixed.firstWhere((r) => r.videoId == 'dup').isLive, isTrue);

    // Few songs: the streams go at the end rather than being dropped.
    expect(
      YouTubeSearchService.mixLive([song('s1')], [live('l1')])
          .map((r) => r.videoId),
      ['s1', 'l1'],
    );
    // Nothing live: the songs come back unchanged.
    final only = [song('s1')];
    expect(identical(YouTubeSearchService.mixLive(only, const []), only), isTrue);
  });
}
