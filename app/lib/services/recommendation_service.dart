import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/song.dart';
import 'youtube_search_service.dart';

/// Representation of a single recommended track from YouTube Music.
class RecommendationItem {
  final String videoId;
  final String title;
  final String artist;
  final Duration? duration;
  final String? thumbnailUrl;

  const RecommendationItem({
    required this.videoId,
    required this.title,
    required this.artist,
    this.duration,
    this.thumbnailUrl,
  });

  String get durationFormatted {
    if (duration == null) return '--:--';
    final m = duration!.inMinutes;
    final s = (duration!.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Converts this recommendation into a playable [Song] model.
  Song toSong({String sourceDeviceId = 'stream'}) {
    final cleanTitle = artist.isNotEmpty && !title.toLowerCase().contains(artist.toLowerCase())
        ? '$title - $artist'
        : title;
    return Song(
      id: 'stream_$videoId',
      title: cleanTitle,
      fileName: '$cleanTitle [$videoId].m4a',
      size: (duration?.inSeconds ?? 200) * 16000, // estimated byte size (~128kbps)
      checksum: 'stream_$videoId',
      sourceDeviceId: sourceDeviceId,
      artwork: thumbnailUrl,
      addedAt: DateTime.now(),
    );
  }

  @override
  String toString() => 'RecommendationItem($title - $artist [$videoId])';
}

/// A paged batch of recommendations with an optional continuation token.
class RecommendationBatch {
  final List<RecommendationItem> items;
  final String? continuationToken;

  const RecommendationBatch({
    required this.items,
    this.continuationToken,
  });

  bool get hasMore => continuationToken != null && continuationToken!.isNotEmpty;
}

/// Core recommendation engine that interfaces with YouTube Music's automix/radio
/// system and provides session de-duplication and offline local library fallbacks.
class RecommendationService {
  static final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 6;
  static final Set<String> _sessionPlayedVideoIds = {};
  static final Map<String, RecommendationBatch> _radioCache = {};
  static const int _maxCacheSize = 25;

  /// Record a video ID or song ID as played in the current session so it won't be repeated.
  static void markPlayed(String id) {
    final cleanId = _extractVideoId(id);
    if (cleanId != null) {
      _sessionPlayedVideoIds.add(cleanId);
    }
  }

  /// Clears the session history.
  static void clearSessionHistory() {
    _sessionPlayedVideoIds.clear();
  }

  /// Tries to extract an 11-character YouTube video ID from a song ID, fileName, or title.
  static String? _extractVideoId(String text) {
    final m = RegExp(r'\[([a-zA-Z0-9_-]{11})\]').firstMatch(text);
    if (m != null) return m.group(1);
    if (text.startsWith('stream_')) {
      final sub = text.replaceFirst('stream_', '');
      if (sub.length == 11) return sub;
    }
    final m2 = RegExp(r'(?:v=|\/)([a-zA-Z0-9_-]{11})(?:[&?]|\b)').firstMatch(text);
    if (m2 != null) return m2.group(1);
    return null;
  }

  /// Parses a duration string like "3:45" or "1:02:15" into a [Duration].
  static Duration? _parseDuration(String? text) {
    if (text == null || text.isEmpty) return null;
    final parts = text.trim().split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]) ?? 0;
      final s = int.tryParse(parts[1]) ?? 0;
      return Duration(minutes: m, seconds: s);
    } else if (parts.length == 3) {
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      final s = int.tryParse(parts[2]) ?? 0;
      return Duration(hours: h, minutes: m, seconds: s);
    }
    return null;
  }

  static final Map<String, String> _seedVideoIdCache = {};

  /// Generates prioritized search query candidates from a song's title and metadata.
  static List<String> generateSearchCandidates(Song song) {
    final candidates = <String>[];

    var base = song.title
        .replaceAll('\uFFFD', ' ')
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
        .replaceAll(RegExp(r'\([^)]*\)'), ' ')
        .replaceAll(RegExp(r'【[^】]*】'), '')
        .replaceAll(RegExp(r'「[^」]*」'), '')
        .replaceAll(RegExp(r'（[^）]*）'), '')
        .replaceAll(RegExp(r'\.(mp3|m4a|flac|wav|ogg|webm|aac|opus|mp4)$', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'^\d+[\s\.\-_]+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (base.isNotEmpty) {
      // Extract clean Latin/alphanumeric prefix if followed by mojibake/corrupted unicode
      final latinPrefixMatch = RegExp(r"^([A-Za-z0-9\s\-_:',\.]+?)(?=\s*[^\x20-\x7E]|$)").firstMatch(base);
      if (latinPrefixMatch != null) {
        final latinPrefix = latinPrefixMatch.group(1)?.trim();
        if (latinPrefix != null && latinPrefix.length >= 4 && latinPrefix.contains(RegExp(r'[A-Za-z]{3,}'))) {
          candidates.add(latinPrefix);
          if (latinPrefix.contains(' - ')) {
            final parts = latinPrefix.split(' - ').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
            if (parts.length >= 2) {
              candidates.add('${parts[1]} ${parts[0]}');
              candidates.add(parts[1]);
              candidates.add(parts[0]);
            }
          }
        }
      }

      // 1. Pipe and slash segment extraction
      final segments = <String>[];
      if (base.contains('|')) {
        segments.addAll(base.split('|').map((s) => s.trim()).where((s) => s.isNotEmpty));
      } else if (base.contains('//')) {
        segments.addAll(base.split('//').map((s) => s.trim()).where((s) => s.isNotEmpty));
      } else {
        segments.add(base);
      }

      for (final seg in segments) {
        final cleanSegMatch = RegExp(r"^([A-Za-z0-9\s\-_:',\.]+?)(?=\s*[^\x20-\x7E]|$)").firstMatch(seg);
        if (cleanSegMatch != null) {
          final p = cleanSegMatch.group(1)?.trim();
          if (p != null && p.isNotEmpty && p.length >= 4) candidates.add(p);
        }

        candidates.add(seg);
        if (seg.contains(' - ')) {
          final parts = seg.split(' - ').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
          if (parts.length >= 2) {
            candidates.add('${parts[1]} ${parts[0]}');
            candidates.add(parts[1]);
            candidates.add(parts[0]);
          }
        }
      }

      // 2. Cleaned base without special punctuation
      final cleanedBase = base.replaceAll(RegExp(r'[|_/\\~]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      candidates.add(cleanedBase);
    }

    final seen = <String>{};
    final unique = <String>[];
    for (final c in candidates) {
      final key = c.toLowerCase().trim();
      if (key.isNotEmpty && key.length >= 2 && seen.add(key)) {
        unique.add(c);
      }
    }
    if (unique.isEmpty) unique.add(song.title.trim());
    return unique;
  }

  /// Cleans a song title or filename for accurate online searching.
  static String cleanSongQuery(Song song) {
    return generateSearchCandidates(song).first;
  }

  /// Resolves the YouTube video ID for a given [Song], querying search if necessary.
  static Future<String?> resolveSeedVideoId(Song song) async {
    final directId = _extractVideoId(song.id) ?? _extractVideoId(song.fileName);
    if (directId != null && directId.isNotEmpty) {
      return directId;
    }

    final candidates = generateSearchCandidates(song);
    for (final query in candidates) {
      final cacheKey = query.toLowerCase();
      if (_seedVideoIdCache.containsKey(cacheKey)) {
        return _seedVideoIdCache[cacheKey];
      }

      // Step 1: Direct Innertube Music Search
      try {
        final innertubeResults = await searchInnertubeSongs(query, limit: 1);
        if (innertubeResults.isNotEmpty) {
          final id = innertubeResults.first.videoId;
          _seedVideoIdCache[cacheKey] = id;
          return id;
        }
      } catch (e) {
        debugPrint('[RecommendationService] Innertube seed search error for "$query": $e');
      }

      // Step 2: YouTubeSearchService fallback
      try {
        final results = await YouTubeSearchService.search(query, limit: 1);
        if (results.isNotEmpty) {
          final id = results.first.videoId;
          _seedVideoIdCache[cacheKey] = id;
          return id;
        }
      } catch (e) {
        debugPrint('[RecommendationService] Search seed resolve failed for "$query": $e');
      }
    }

    return null;
  }

  /// Fetches an initial radio mix of ~25-50 contextually related songs for [song].
  static Future<RecommendationBatch> fetchRadio(
    Song song, {
    Set<String>? excludeVideoIds,
  }) async {
    final videoId = await resolveSeedVideoId(song);

    if (videoId != null && videoId.isNotEmpty) {
      if (_radioCache.containsKey(videoId)) {
        return _radioCache[videoId]!;
      }

      // Attempt 1: Multi-client Innertube next endpoint with RDAMVM automix
      final automixBatch = await _fetchInnertubeRadio(
        videoId,
        playlistPrefix: 'RDAMVM',
        excludeVideoIds: excludeVideoIds,
      );
      if (automixBatch.items.isNotEmpty) {
        _cacheRadioBatch(videoId, automixBatch);
        return automixBatch;
      }

      // Attempt 2: Innertube next endpoint with pure RD playlist
      final rdBatch = await _fetchInnertubeRadio(
        videoId,
        playlistPrefix: 'RD',
        excludeVideoIds: excludeVideoIds,
      );
      if (rdBatch.items.isNotEmpty) {
        _cacheRadioBatch(videoId, rdBatch);
        return rdBatch;
      }

      // Attempt 3: Innertube next endpoint without playlist (Up Next queue)
      final upNextBatch = await _fetchInnertubeRadio(
        videoId,
        playlistPrefix: null,
        excludeVideoIds: excludeVideoIds,
      );
      if (upNextBatch.items.isNotEmpty) {
        _cacheRadioBatch(videoId, upNextBatch);
        return upNextBatch;
      }
    }

    // Attempt 4: Fallback related tracks via Innertube song search & YouTube search automix
    final fallbackBatch = await _fetchFallbackRelated(song, videoId, excludeVideoIds: excludeVideoIds);
    if (fallbackBatch.items.isNotEmpty) {
      if (videoId != null) _cacheRadioBatch(videoId, fallbackBatch);
      return fallbackBatch;
    }

    return const RecommendationBatch(items: []);
  }

  static void _cacheRadioBatch(String videoId, RecommendationBatch batch) {
    if (_radioCache.length >= _maxCacheSize) {
      _radioCache.remove(_radioCache.keys.first);
    }
    _radioCache[videoId] = batch;
  }

  static Future<RecommendationBatch> _fetchInnertubeRadio(
    String videoId, {
    String? playlistPrefix = 'RDAMVM',
    Set<String>? excludeVideoIds,
  }) async {
    final clientConfigs = [
      {
        'clientName': 'WEB_REMIX',
        'clientVersion': '1.20260801.01.00',
        'userAgent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'referer': 'https://music.youtube.com/',
      },
      {
        'clientName': 'ANDROID_MUSIC',
        'clientVersion': '6.42.52',
        'userAgent': 'com.google.android.apps.youtube.music/6.42.52 (Linux; U; Android 14)',
        'referer': 'https://music.youtube.com/',
      },
    ];

    for (final cfg in clientConfigs) {
      try {
        final request = await _httpClient.postUrl(
          Uri.parse('https://music.youtube.com/youtubei/v1/next'),
        );
        request.headers.set('Content-Type', 'application/json');
        request.headers.set('User-Agent', cfg['userAgent']!);
        request.headers.set('Referer', cfg['referer']!);

        final payload = <String, dynamic>{
          'context': {
            'client': {
              'clientName': cfg['clientName'],
              'clientVersion': cfg['clientVersion'],
              'hl': 'en',
              'gl': 'US',
            }
          },
          'videoId': videoId,
        };

        if (playlistPrefix != null) {
          payload['playlistId'] = '$playlistPrefix$videoId';
        }

        request.write(jsonEncode(payload));
        final response = await request.close().timeout(const Duration(seconds: 6));
        if (response.statusCode != 200) {
          continue;
        }

        final respText = await response.transform(utf8.decoder).join();
        final data = jsonDecode(respText) as Map<String, dynamic>;

        final panel = data['contents']?['singleColumnMusicWatchNextResultsRenderer']
            ?['tabbedRenderer']?['watchNextTabbedResultsRenderer']?['tabs']?[0]
            ?['tabRenderer']?['content']?['musicQueueRenderer']?['content']
            ?['playlistPanelRenderer'];

        final rawItems = panel?['contents'] as List?;
        final items = <RecommendationItem>[];
        final seen = <String>{...?excludeVideoIds, ..._sessionPlayedVideoIds, videoId};

        if (rawItems != null && rawItems.isNotEmpty) {
          for (final item in rawItems) {
            final renderer = item['playlistPanelVideoRenderer'];
            if (renderer == null) continue;
            final vId = renderer['videoId'] as String?;
            if (vId == null || vId.isEmpty || seen.contains(vId)) continue;
            seen.add(vId);

            final titleRuns = renderer['title']?['runs'] as List?;
            final title = titleRuns != null && titleRuns.isNotEmpty
                ? titleRuns[0]['text'] as String? ?? 'Unknown Title'
                : 'Unknown Title';

            final bylineRuns = renderer['longBylineText']?['runs'] as List?;
            final artist = bylineRuns != null && bylineRuns.isNotEmpty
                ? bylineRuns[0]['text'] as String? ?? ''
                : '';

            final lengthRuns = renderer['lengthText']?['runs'] as List?;
            final lengthStr = lengthRuns != null && lengthRuns.isNotEmpty
                ? lengthRuns[0]['text'] as String?
                : null;

            final thumbs = renderer['thumbnail']?['thumbnails'] as List?;
            final thumbUrl = thumbs != null && thumbs.isNotEmpty
                ? thumbs.last['url'] as String?
                : null;

            items.add(
              RecommendationItem(
                videoId: vId,
                title: title,
                artist: artist,
                duration: _parseDuration(lengthStr),
                thumbnailUrl: thumbUrl,
              ),
            );
          }
        }

        String? continuationToken;
        final continuations = panel?['continuations'] as List?;
        if (continuations != null && continuations.isNotEmpty) {
          continuationToken = continuations[0]['nextContinuationData']?['continuation'] as String?;
        }

        if (items.isNotEmpty) {
          return RecommendationBatch(
            items: items,
            continuationToken: continuationToken,
          );
        }
      } catch (e) {
        debugPrint('[RecommendationService] Innertube client ${cfg['clientName']} failed: $e');
      }
    }
    return const RecommendationBatch(items: []);
  }

  /// Searches Innertube Music directly for song tracks.
  static Future<List<RecommendationItem>> searchInnertubeSongs(String query, {int limit = 20}) async {
    final clientConfigs = [
      {
        'clientName': 'WEB_REMIX',
        'clientVersion': '1.20260801.01.00',
        'userAgent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      },
    ];

    for (final cfg in clientConfigs) {
      try {
        final request = await _httpClient.postUrl(
          Uri.parse('https://music.youtube.com/youtubei/v1/search'),
        );
        request.headers.set('Content-Type', 'application/json');
        request.headers.set('User-Agent', cfg['userAgent']!);
        request.headers.set('Referer', 'https://music.youtube.com/');

        final payload = {
          'context': {
            'client': {
              'clientName': cfg['clientName'],
              'clientVersion': cfg['clientVersion'],
              'hl': 'en',
              'gl': 'US',
            }
          },
          'query': query,
          'params': 'EgWKAQIIAWoKEAUQCRADEAQQBQ==', // Song filter
        };

        request.write(jsonEncode(payload));
        final response = await request.close().timeout(const Duration(seconds: 6));
        if (response.statusCode != 200) continue;

        final respText = await response.transform(utf8.decoder).join();
        final data = jsonDecode(respText) as Map<String, dynamic>;

        final items = <RecommendationItem>[];
        final sections = data['contents']?['tabbedSearchResultsRenderer']?['tabs']?[0]
            ?['tabRenderer']?['content']?['sectionListRenderer']?['contents'] as List?;

        if (sections != null) {
          for (final sec in sections) {
            final shelf = sec['musicShelfRenderer'];
            final shelfContents = shelf?['contents'] as List?;
            if (shelfContents == null) continue;

            for (final row in shelfContents) {
              if (items.length >= limit) break;
              final renderer = row['musicResponsiveListItemRenderer'];
              if (renderer == null) continue;

              final flexCols = renderer['flexColumns'] as List?;
              if (flexCols == null || flexCols.isEmpty) continue;

              final titleRuns = flexCols[0]?['musicResponsiveListItemFlexColumnRenderer']
                  ?['text']?['runs'] as List?;
              final title = titleRuns != null && titleRuns.isNotEmpty
                  ? titleRuns[0]['text'] as String? ?? 'Unknown'
                  : 'Unknown';

              String artist = '';
              String? lengthStr;
              if (flexCols.length > 1) {
                final subRuns = flexCols[1]?['musicResponsiveListItemFlexColumnRenderer']
                    ?['text']?['runs'] as List?;
                if (subRuns != null && subRuns.isNotEmpty) {
                  artist = subRuns[0]['text'] as String? ?? '';
                  if (subRuns.length >= 3) {
                    lengthStr = subRuns.last['text'] as String?;
                  }
                }
              }

              final playNav = renderer['overlay']?['musicItemThumbnailOverlayRenderer']
                  ?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint'];
              final vId = playNav?['watchEndpoint']?['videoId'] as String? ??
                  renderer['playlistItemData']?['videoId'] as String?;

              if (vId == null || vId.isEmpty) continue;

              final thumbs = renderer['thumbnail']?['musicThumbnailRenderer']
                  ?['thumbnail']?['thumbnails'] as List?;
              final thumbUrl = thumbs != null && thumbs.isNotEmpty
                  ? thumbs.last['url'] as String?
                  : null;

              items.add(
                RecommendationItem(
                  videoId: vId,
                  title: title,
                  artist: artist,
                  duration: _parseDuration(lengthStr),
                  thumbnailUrl: thumbUrl,
                ),
              );
            }
          }
        }

        if (items.isNotEmpty) return items;
      } catch (e) {
        debugPrint('[RecommendationService] Innertube search error: $e');
      }
    }
    return const [];
  }

  static Future<RecommendationBatch> _fetchFallbackRelated(
    Song song,
    String? videoId, {
    Set<String>? excludeVideoIds,
  }) async {
    try {
      final candidates = generateSearchCandidates(song);
      final seen = <String>{
        ...?excludeVideoIds,
        ..._sessionPlayedVideoIds,
        if (videoId != null) videoId,
      };
      final items = <RecommendationItem>[];

      for (final query in candidates) {
        // Strategy A: Innertube Music search for "$query"
        final innertubeMatches = await searchInnertubeSongs(query, limit: 20);
        for (final r in innertubeMatches) {
          if (seen.contains(r.videoId)) continue;
          seen.add(r.videoId);
          items.add(r);
        }

        if (items.length >= 10) break;

        // Strategy B: YouTubeSearchService for "$query mix"
        final results = await YouTubeSearchService.search('$query mix', limit: 20);
        for (final r in results) {
          if (seen.contains(r.videoId)) continue;
          seen.add(r.videoId);
          items.add(
            RecommendationItem(
              videoId: r.videoId,
              title: r.title,
              artist: r.author,
              duration: r.duration,
              thumbnailUrl: r.thumbnailUrl,
            ),
          );
        }

        if (items.length >= 5) break;
      }

      if (items.isNotEmpty) {
        return RecommendationBatch(items: items);
      }
      return const RecommendationBatch(items: []);
    } catch (e) {
      debugPrint('[RecommendationService] Fallback search error: $e');
      return const RecommendationBatch(items: []);
    }
  }

  /// Fetches the next paged batch of recommendations using a [continuationToken].
  static Future<RecommendationBatch> fetchContinuation(
    String continuationToken, {
    Set<String>? excludeVideoIds,
  }) async {
    final clientConfigs = [
      {
        'clientName': 'WEB_REMIX',
        'clientVersion': '1.20260801.01.00',
        'userAgent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'referer': 'https://music.youtube.com/',
      },
    ];

    for (final cfg in clientConfigs) {
      try {
        final request = await _httpClient.postUrl(
          Uri.parse('https://music.youtube.com/youtubei/v1/next'),
        );
        request.headers.set('Content-Type', 'application/json');
        request.headers.set('User-Agent', cfg['userAgent']!);
        request.headers.set('Referer', cfg['referer']!);

        final body = jsonEncode({
          'context': {
            'client': {
              'clientName': cfg['clientName'],
              'clientVersion': cfg['clientVersion'],
              'hl': 'en',
              'gl': 'US',
            }
          },
          'continuation': continuationToken,
        });

        request.write(body);
        final response = await request.close().timeout(const Duration(seconds: 6));
        if (response.statusCode != 200) continue;

        final respText = await response.transform(utf8.decoder).join();
        final data = jsonDecode(respText) as Map<String, dynamic>;

        final continuations = data['continuationContents']?['playlistPanelContinuation'];
        final rawItems = continuations?['contents'] as List?;
        final items = <RecommendationItem>[];
        final seen = <String>{...?excludeVideoIds, ..._sessionPlayedVideoIds};

        if (rawItems != null && rawItems.isNotEmpty) {
          for (final item in rawItems) {
            final renderer = item['playlistPanelVideoRenderer'];
            if (renderer == null) continue;
            final vId = renderer['videoId'] as String?;
            if (vId == null || vId.isEmpty || seen.contains(vId)) continue;
            seen.add(vId);

            final titleRuns = renderer['title']?['runs'] as List?;
            final title = titleRuns != null && titleRuns.isNotEmpty
                ? titleRuns[0]['text'] as String? ?? 'Unknown Title'
                : 'Unknown Title';

            final bylineRuns = renderer['longBylineText']?['runs'] as List?;
            final artist = bylineRuns != null && bylineRuns.isNotEmpty
                ? bylineRuns[0]['text'] as String? ?? ''
                : '';

            final lengthRuns = renderer['lengthText']?['runs'] as List?;
            final lengthStr = lengthRuns != null && lengthRuns.isNotEmpty
                ? lengthRuns[0]['text'] as String?
                : null;

            final thumbs = renderer['thumbnail']?['thumbnails'] as List?;
            final thumbUrl = thumbs != null && thumbs.isNotEmpty
                ? thumbs.last['url'] as String?
                : null;

            items.add(
              RecommendationItem(
                videoId: vId,
                title: title,
                artist: artist,
                duration: _parseDuration(lengthStr),
                thumbnailUrl: thumbUrl,
              ),
            );
          }
        }

        String? nextToken;
        final nextContinuations = continuations?['continuations'] as List?;
        if (nextContinuations != null && nextContinuations.isNotEmpty) {
          nextToken = nextContinuations[0]['nextContinuationData']?['continuation'] as String?;
        }

        if (items.isNotEmpty) {
          return RecommendationBatch(
            items: items,
            continuationToken: nextToken,
          );
        }
      } catch (e) {
        debugPrint('[RecommendationService] fetchContinuation error: $e');
      }
    }
    return const RecommendationBatch(items: []);
  }

  /// Offline fallback: intelligently sorts existing [librarySongs] by matching
  /// artist names and keywords in [seedSong.title].
  static List<Song> getOfflineRecommendations(
    Song seedSong,
    List<Song> librarySongs, {
    Set<String>? excludeSongIds,
  }) {
    if (librarySongs.isEmpty) return const [];
    final pool = librarySongs.where((s) => s.id != seedSong.id && !(excludeSongIds?.contains(s.id) ?? false)).toList();
    if (pool.isEmpty) return const [];

    final seedTokens = seedSong.title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .split(RegExp(r'\s+'))
        .where((t) => t.length > 2)
        .toSet();

    pool.sort((a, b) {
      int scoreA = 0;
      int scoreB = 0;

      final titleA = a.title.toLowerCase();
      final titleB = b.title.toLowerCase();

      for (final t in seedTokens) {
        if (titleA.contains(t)) scoreA += 2;
        if (titleB.contains(t)) scoreB += 2;
      }

      return scoreB.compareTo(scoreA);
    });

    return pool.take(10).toList();
  }
}
