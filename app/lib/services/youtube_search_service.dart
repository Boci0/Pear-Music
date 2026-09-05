import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/song.dart';
import 'recommendation_service.dart';

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

  /// Converts this search result into a playable [Song] stream model.
  Song toSong({String sourceDeviceId = 'stream'}) {
    final cleanTitle = author.isNotEmpty && !title.toLowerCase().contains(author.toLowerCase())
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

  /// Search YouTube for songs/videos matching [query].
  static Future<List<YouTubeSearchResult>> search(String query, {int limit = 20}) async {
    final clean = query.trim().toLowerCase();
    if (clean.isEmpty) return const [];

    if (_cache.containsKey(clean)) {
      return _cache[clean]!;
    }

    // 1. Primary: YouTube Music Innertube API (structured, resilient, not blocked by 400)
    try {
      final innertubeResults = await RecommendationService.searchInnertubeSongs(clean, limit: limit);
      if (innertubeResults.isNotEmpty) {
        final list = innertubeResults
            .map((item) => YouTubeSearchResult(
                  videoId: item.videoId,
                  title: item.title,
                  author: item.artist,
                  duration: item.duration,
                  thumbnailUrl: item.thumbnailUrl,
                ))
            .toList();

        if (_cache.length >= _maxCacheEntries) {
          _cache.remove(_cache.keys.first);
        }
        _cache[clean] = list;
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

  /// Close client resources and clear memory caches.
  static void dispose() {
    _cache.clear();
    _yt?.close();
    _yt = null;
  }
}
