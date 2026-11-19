import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/song.dart';
import 'backup_audio_engine.dart';
import 'recommendation_service.dart';
import 'text_repair.dart';

/// Representation of a YouTube search track result.
class YouTubeSearchResult {
  final String videoId;

  /// The title with any code-page decoding mistakes repaired, so search rows
  /// show the real characters even when a lookup comes back garbled.
  final String title;
  final String author;
  final Duration? duration;
  final String? thumbnailUrl;

  /// Live right now: it has no length, so rows show a LIVE badge instead.
  final bool isLive;

  YouTubeSearchResult({
    required this.videoId,
    required String title,
    required String author,
    this.duration,
    this.thumbnailUrl,
    this.isLive = false,
  })  : title = TextRepair.title(title),
        author = TextRepair.title(author);

  String get url => 'https://www.youtube.com/watch?v=$videoId';

  String get durationFormatted {
    if (duration == null) return '--:--';
    final value = duration!;
    final s = (value.inSeconds % 60).toString().padLeft(2, '0');
    final h = value.inHours;
    if (h > 0) {
      final m = (value.inMinutes % 60).toString().padLeft(2, '0');
      return '$h:$m:$s';
    }
    return '${value.inMinutes}:$s';
  }

  /// Converts this search result into a playable [Song] stream model.
  Song toSong({String sourceDeviceId = 'stream'}) {
    final cleanTitle =
        author.isNotEmpty && !title.toLowerCase().contains(author.toLowerCase())
        ? '$title - $author'
        : title;
    return Song(
      id: 'stream_$videoId',
      title: cleanTitle,
      fileName: '$cleanTitle [$videoId].m4a',
      size: (duration?.inSeconds ?? 200) * 16000,
      checksum: 'stream_$videoId',
      sourceDeviceId: sourceDeviceId,
      artwork: thumbnailUrl,
      artist: author.isEmpty ? null : author,
      isLive: isLive,
      addedAt: DateTime.now(),
    );
  }
}

/// Service that handles searching YouTube and extracting playable audio stream URLs.
class YouTubeSearchService {
  static YoutubeExplode? _yt;
  static final Map<String, List<YouTubeSearchResult>> _cache = {};
  static const int _maxCacheEntries = 40;

  static YoutubeExplode get _client => _yt ??= YoutubeExplode();
  static bool allowVideoResults = false;

  static final RegExp _videoIdRegExp = RegExp(r'^[a-zA-Z0-9_-]{11}$');

  @visibleForTesting
  static Future<YouTubeSearchResult?> Function(String videoId)? debugVideoLookup;

  @visibleForTesting
  static Future<List<YouTubeSearchResult>> Function(
    String query, {
    required int limit,
    required bool enableVideos,
  })? debugSearchOverride;

  /// Clears the in-memory search query cache.
  static void clearCache() {
    _cache.clear();
  }

  static void _storeCache(String key, List<YouTubeSearchResult> list) {
    if (_cache.length >= _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = list;
  }

  /// Extracts an 11-character video ID when [input] is an explicit video URL,
  /// returning null for plain search keywords (even 11-character words).
  static String? extractDirectVideoId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty || RegExp(r'\s').hasMatch(trimmed)) return null;
    var candidateUrl = trimmed;
    final lower = candidateUrl.toLowerCase();
    if (lower.startsWith('youtube.com/') ||
        lower.startsWith('www.youtube.com/') ||
        lower.startsWith('m.youtube.com/') ||
        lower.startsWith('music.youtube.com/') ||
        lower.startsWith('youtu.be/')) {
      candidateUrl = 'https://$candidateUrl';
    }
    final uri = Uri.tryParse(candidateUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final host = uri.host.toLowerCase();
    String? id;
    if (host == 'youtu.be') {
      id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    } else if (const {
      'youtube.com',
      'www.youtube.com',
      'm.youtube.com',
      'music.youtube.com',
    }.contains(host)) {
      final first = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
      if (first == 'watch') {
        id = uri.queryParameters['v'];
      } else if (uri.pathSegments.length >= 2 &&
          const {'shorts', 'live', 'embed'}.contains(first)) {
        id = uri.pathSegments[1];
      }
    }
    if (id == null || !_videoIdRegExp.hasMatch(id)) return null;
    return id;
  }

  /// Resolves metadata for a pasted video link directly by [videoId].
  static Future<List<YouTubeSearchResult>> lookupByVideoId(
    String videoId, {
    bool throwOnError = false,
  }) async {
    if (!_videoIdRegExp.hasMatch(videoId)) return const [];
    final cacheKey = 'vid:$videoId';
    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    if (debugVideoLookup != null) {
      try {
        final picked = await debugVideoLookup!(videoId);
        if (picked == null) return const [];
        final list = [picked];
        _storeCache(cacheKey, list);
        return list;
      } catch (_) {
        if (throwOnError) rethrow;
        return const [];
      }
    }

    final Object primaryError;
    try {
      final video = await _client.videos
          .get(videoId)
          .timeout(const Duration(seconds: 10));
      final result = YouTubeSearchResult(
        videoId: video.id.value,
        title: video.title,
        author: video.author,
        duration: video.duration,
        isLive: video.isLive,
        thumbnailUrl: video.thumbnails.highResUrl.isNotEmpty
            ? video.thumbnails.highResUrl
            : (video.thumbnails.mediumResUrl.isNotEmpty
                  ? video.thumbnails.mediumResUrl
                  : video.thumbnails.lowResUrl),
      );
      final list = [result];
      _storeCache(cacheKey, list);
      return list;
    } catch (e) {
      primaryError = e;
      debugPrint('[YouTubeSearchService] Direct lookup fallback for $videoId: $e');
    }

    try {
      final client = _liveClient ??= BackupAudioEngine.ipv4Client();
      final res = await client
          .get(
            Uri.https('www.youtube.com', '/oembed', {
              'url': 'https://www.youtube.com/watch?v=$videoId',
              'format': 'json',
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (data is Map) {
          final title = (data['title'] as String? ?? '').trim();
          if (title.isNotEmpty) {
            final result = YouTubeSearchResult(
              videoId: videoId,
              title: title,
              author: (data['author_name'] as String? ?? '').trim(),
              thumbnailUrl: data['thumbnail_url'] as String?,
            );
            final list = [result];
            _storeCache(cacheKey, list);
            return list;
          }
        }
      }
      if (res.statusCode == 400 ||
          res.statusCode == 401 ||
          res.statusCode == 404) {
        return const [];
      }
    } catch (e) {
      debugPrint('[YouTubeSearchService] oEmbed lookup error for $videoId: $e');
    }

    if (throwOnError) {
      throw primaryError;
    }
    return const [];
  }

  static http.Client? _liveClient;

  /// Streams that are live right now and match [query], found with YouTube's
  /// own Live filter. [search] never lists them (the Songs filter it uses
  /// leaves out anything that is not a finished song), which is why a live
  /// stream was so hard to come across. An empty list when the lookup fails,
  /// unless [throwOnError] is true.
  static Future<List<YouTubeSearchResult>> searchLive(
    String query, {
    int limit = 30,
    bool throwOnError = false,
  }) async {
    final clean = query.trim();
    if (clean.isEmpty) return const [];
    final key = 'live:${clean.toLowerCase()}';
    final cached = _cache[key];
    if (cached != null) return cached.take(limit).toList();
    try {
      final client = _liveClient ??= BackupAudioEngine.ipv4Client();
      final res = await client
          .post(
            Uri.parse('https://www.youtube.com/youtubei/v1/search?prettyPrint=false'),
            headers: const {
              'Content-Type': 'application/json',
              'User-Agent': 'Mozilla/5.0',
            },
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': 'WEB',
                  'clientVersion': '2.20250101.00.00',
                  'hl': 'en',
                },
              },
              'query': clean,
              // The "Live" filter of YouTube's search.
              'params': 'EgJAAQ==',
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        if (throwOnError) {
          throw HttpException('Live search failed (${res.statusCode})');
        }
        return const [];
      }
      final list = parseLiveResults(jsonDecode(utf8.decode(res.bodyBytes)));
      _storeCache(key, list);
      return list.take(limit).toList();
    } catch (e) {
      debugPrint('[YouTubeSearchService] Live search error: $e');
      if (throwOnError) rethrow;
      return const [];
    }
  }

  /// Reads the video rows of a YouTube search response, keeping the ones that
  /// are live now.
  @visibleForTesting
  static List<YouTubeSearchResult> parseLiveResults(Object? json) {
    final out = <YouTubeSearchResult>[];
    final seen = <String>{};

    String text(Object? node) {
      if (node is! Map) return '';
      final simple = node['simpleText'];
      if (simple is String) return simple;
      final runs = node['runs'];
      if (runs is List) {
        return runs.map((r) => r is Map ? '${r['text'] ?? ''}' : '').join();
      }
      return '';
    }

    void walk(Object? node) {
      if (node is List) {
        for (final c in node) {
          walk(c);
        }
        return;
      }
      if (node is! Map) return;
      final v = node['videoRenderer'];
      if (v is Map) {
        final id = v['videoId'];
        final badges = [
          for (final b in (v['badges'] as List? ?? const []))
            if (b is Map) (b['metadataBadgeRenderer'] as Map?)?['style'],
        ];
        final overlays = [
          for (final o in (v['thumbnailOverlays'] as List? ?? const []))
            if (o is Map)
              (o['thumbnailOverlayTimeStatusRenderer'] as Map?)?['style'],
        ];
        final live = badges.contains('BADGE_STYLE_TYPE_LIVE_NOW') ||
            overlays.contains('LIVE');
        if (id is String && live && seen.add(id)) {
          final thumbs = (v['thumbnail'] as Map?)?['thumbnails'];
          final thumb = thumbs is List && thumbs.isNotEmpty && thumbs.last is Map
              ? (thumbs.last as Map)['url'] as String?
              : null;
          out.add(
            YouTubeSearchResult(
              videoId: id,
              title: text(v['title']),
              author: text(v['ownerText'] ?? v['longBylineText']),
              thumbnailUrl: thumb,
              isLive: true,
            ),
          );
        }
        return;
      }
      for (final c in node.values) {
        walk(c);
      }
    }

    walk(json);
    return out;
  }

  /// Search YouTube for songs/videos matching [query].
  ///
  /// With [includeLive], a few streams that are live right now are mixed in
  /// among the first results: the Songs filter leaves them out entirely, so
  /// they could not be found by a plain search. Only the search box asks for
  /// this; the recommendation and radio lookups that share this method stay
  /// songs only.
  static Future<List<YouTubeSearchResult>> search(
    String query, {
    int limit = 20,
    bool? allowVideoResults,
    bool includeLive = false,
    bool throwOnError = false,
    void Function(List<YouTubeSearchResult> firstPage)? onFirstPage,
  }) async {
    final directId = extractDirectVideoId(query);
    if (directId != null) {
      return await lookupByVideoId(directId, throwOnError: throwOnError);
    }
    // Started first so it runs alongside the songs lookup. It never throws.
    final live = includeLive ? searchLive(query, limit: 30) : null;
    final songs = await _searchSongs(
      query,
      limit: limit,
      allowVideoResults: allowVideoResults,
      throwOnError: throwOnError,
      onFirstPage: onFirstPage,
    );
    if (live == null) return songs;
    return mixLive(songs, await live);
  }

  /// Marks the song rows that are really live streams (the Songs filter does
  /// not always carry the live badge, so a well-known stream could sit there
  /// unmarked) and puts the first [show] other live streams among [songs],
  /// from [at] on.
  @visibleForTesting
  static List<YouTubeSearchResult> mixLive(
    List<YouTubeSearchResult> songs,
    List<YouTubeSearchResult> live, {
    int at = 3,
    int show = 3,
  }) {
    if (live.isEmpty) return songs;
    final liveById = {for (final l in live) l.videoId: l};
    final present = {for (final s in songs) s.videoId};
    final marked = [
      for (final s in songs) liveById[s.videoId] ?? s,
    ];
    final extra = [
      for (final l in live)
        if (!present.contains(l.videoId)) l,
    ].take(show).toList();
    final index = at < marked.length ? at : marked.length;
    return [...marked.take(index), ...extra, ...marked.skip(index)];
  }

  /// When the expanded scope (video results) finds nothing, the search is
  /// repeated with it off so a query never comes back empty because of it.
  static Future<List<YouTubeSearchResult>> _searchSongs(
    String query, {
    int limit = 20,
    bool? allowVideoResults,
    bool throwOnError = false,
    void Function(List<YouTubeSearchResult> firstPage)? onFirstPage,
  }) async {
    final bool enableVideos =
        allowVideoResults ?? YouTubeSearchService.allowVideoResults;
    final results = await _search(
      query,
      limit: limit,
      enableVideos: enableVideos,
      throwOnError: throwOnError,
      onFirstPage: onFirstPage,
    );
    if (results.isNotEmpty || !enableVideos) return results;
    return _search(
      query,
      limit: limit,
      enableVideos: false,
      throwOnError: throwOnError,
      onFirstPage: onFirstPage,
    );
  }

  static Future<List<YouTubeSearchResult>> _search(
    String query, {
    required int limit,
    required bool enableVideos,
    bool throwOnError = false,
    void Function(List<YouTubeSearchResult> firstPage)? onFirstPage,
  }) async {
    final clean = query.trim().toLowerCase();
    if (clean.isEmpty) return const [];

    final cacheKey = '$clean:$enableVideos';

    final cached = _cache[cacheKey];
    if (cached != null) {
      if (cached.length >= limit) {
        return cached.take(limit).toList();
      }
      // A smaller earlier request (path resolution, radio seed lookup) cached
      // a short list for this query. Fall through to fetch a full set so an
      // expanded search never returns fewer results than a tiny lookup.
    }

    if (debugSearchOverride != null) {
      try {
        final list = await debugSearchOverride!(
          clean,
          limit: limit,
          enableVideos: enableVideos,
        );
        if (list.isNotEmpty) _storeCache(cacheKey, list);
        return list.take(limit).toList();
      } catch (_) {
        if (throwOnError) rethrow;
        return const [];
      }
    }

    // 1. Primary: YouTube Music Innertube API (structured, resilient, not blocked by 400)
    try {
      final innertubeResults = await RecommendationService.searchInnertubeSongs(
        clean,
        limit: limit,
        allowVideoResults: enableVideos,
        onFirstPage: onFirstPage == null
            ? null
            : (page) => onFirstPage(page.map(_fromItem).toList()),
      );
      if (innertubeResults.isNotEmpty) {
        final list = innertubeResults
            .map(_fromItem)
            .toList();

        _storeCache(cacheKey, list);
        return list;
      }
    } catch (e) {
      debugPrint('[YouTubeSearchService] Innertube search fallback: $e');
    }

    // 2. Fallback: youtube_explode HTML scraper
    try {
      final searchResults = await _client.search.search(clean);
      final list = <YouTubeSearchResult>[];

      for (final video in searchResults) {
        if (list.length >= limit) break;
        list.add(
          YouTubeSearchResult(
            videoId: video.id.value,
            title: video.title,
            author: video.author,
            duration: video.duration,
            isLive: video.isLive,
            thumbnailUrl: video.thumbnails.highResUrl.isNotEmpty
                ? video.thumbnails.highResUrl
                : (video.thumbnails.mediumResUrl.isNotEmpty
                      ? video.thumbnails.mediumResUrl
                      : video.thumbnails.lowResUrl),
          ),
        );
      }

      _storeCache(cacheKey, list);

      return list;
    } catch (e) {
      debugPrint('[YouTubeSearchService] Search error: $e');
      if (throwOnError) rethrow;
      return const [];
    }
  }

  static YouTubeSearchResult _fromItem(RecommendationItem item) =>
      YouTubeSearchResult(
        videoId: item.videoId,
        title: item.title,
        author: item.artist,
        duration: item.duration,
        thumbnailUrl: item.thumbnailUrl,
        isLive: item.isLive,
      );

  /// Test seam: whether the live-search client is still held.
  @visibleForTesting
  static bool get debugHasLiveClient => _liveClient != null;

  /// Test seam: replaces the live-search client so a test can watch it close.
  @visibleForTesting
  static void debugSetLiveClient(http.Client? client) => _liveClient = client;

  /// Close client resources and clear memory caches.
  static void dispose() {
    _cache.clear();
    debugVideoLookup = null;
    debugSearchOverride = null;
    _yt?.close();
    _yt = null;
    _liveClient?.close();
    _liveClient = null;
  }
}
