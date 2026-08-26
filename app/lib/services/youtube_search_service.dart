import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Representation of a YouTube search track result.
class YouTubeSearchResult {
  final String videoId;
  final String title;
  final String author;
  final Duration? duration;
  final String? thumbnailUrl;

  const YouTubeSearchResult({
    required this.videoId,
    required this.title,
    required this.author,
    this.duration,
    this.thumbnailUrl,
  });

  String get url => 'https://www.youtube.com/watch?v=$videoId';

  String get durationFormatted {
    if (duration == null) return '--:--';
    final m = duration!.inMinutes;
    final s = (duration!.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Service that handles searching YouTube and extracting playable audio stream URLs.
class YouTubeSearchService {
  static YoutubeExplode? _yt;
  static final Map<String, List<YouTubeSearchResult>> _cache = {};
  static const int _maxCacheEntries = 40;

  static YoutubeExplode get _client => _yt ??= YoutubeExplode();

  /// Search YouTube for songs/videos matching [query].
  static Future<List<YouTubeSearchResult>> search(String query, {int limit = 20}) async {
    final clean = query.trim().toLowerCase();
    if (clean.isEmpty) return const [];

    if (_cache.containsKey(clean)) {
      return _cache[clean]!;
    }

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
            thumbnailUrl: video.thumbnails.highResUrl.isNotEmpty
                ? video.thumbnails.highResUrl
                : (video.thumbnails.mediumResUrl.isNotEmpty
                    ? video.thumbnails.mediumResUrl
                    : video.thumbnails.lowResUrl),
          ),
        );
      }

      if (_cache.length >= _maxCacheEntries) {
        _cache.remove(_cache.keys.first);
      }
      _cache[clean] = list;

      return list;
    } catch (e) {
      debugPrint('[YouTubeSearchService] Search error: $e');
      return const [];
    }
  }

  /// Close client resources.
  static void dispose() {
    _yt?.close();
    _yt = null;
  }
}
