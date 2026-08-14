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

  static YoutubeExplode get _client => _yt ??= YoutubeExplode();

  /// Search YouTube for songs/videos matching [query].
  static Future<List<YouTubeSearchResult>> search(String query, {int limit = 20}) async {
    final clean = query.trim();
    if (clean.isEmpty) return const [];

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
            thumbnailUrl: video.thumbnails.lowResUrl,
          ),
        );
      }
      return list;
    } catch (e) {
      debugPrint('[YouTubeSearchService] Search error: $e');
      return const [];
    }
  }

  /// Extracts the direct audio stream URL for a given [videoId].
  static Future<Uri?> getAudioStreamUri(String videoId) async {
    try {
      final manifest = await _client.videos.streamsClient.getManifest(videoId);
      final audioStreams = manifest.audioOnly;
      if (audioStreams.isEmpty) return null;

      // Select the audio stream with the highest bitrate (opus/m4a).
      final bestAudio = audioStreams.withHighestBitrate();
      return bestAudio.url;
    } catch (e) {
      debugPrint('[YouTubeSearchService] Stream extraction error for $videoId: $e');
      return null;
    }
  }

  /// Close client resources.
  static void dispose() {
    _yt?.close();
    _yt = null;
  }
}
