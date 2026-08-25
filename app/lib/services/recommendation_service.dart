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
      artwork: null,
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
  static final HttpClient _httpClient = HttpClient();
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

  /// Fetches an initial radio mix of ~25-50 contextually related songs for [song].
  static Future<RecommendationBatch> fetchRadio(
    Song song, {
    Set<String>? excludeVideoIds,
  }) async {
    var videoId = _extractVideoId(song.id) ?? _extractVideoId(song.fileName);

    if (videoId == null || videoId.isEmpty) {
      final query = song.title.replaceAll(RegExp(r'\s+\[[^\]]+\]$'), '').trim();
      final results = await YouTubeSearchService.search(query, limit: 1);
      if (results.isNotEmpty) {
        videoId = results.first.videoId;
      }
    }

    if (videoId == null || videoId.isEmpty) {
      debugPrint('[RecommendationService] Could not resolve videoId for "${song.title}"');
      return const RecommendationBatch(items: []);
    }

    if (_radioCache.containsKey(videoId)) {
      return _radioCache[videoId]!;
    }

    try {
      final request = await _httpClient.postUrl(
        Uri.parse('https://music.youtube.com/youtubei/v1/next'),
      );
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');
      request.headers.set('Referer', 'https://music.youtube.com/');

      final body = jsonEncode({
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': '1.20260801.01.00',
            'hl': 'en',
            'gl': 'US',
          }
        },
        'videoId': videoId,
        'playlistId': 'RDAMVM$videoId',
      });

      request.write(body);
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('[RecommendationService] API HTTP error: ${response.statusCode}');
        return const RecommendationBatch(items: []);
      }

      final respText = await response.transform(utf8.decoder).join();
      final data = jsonDecode(respText) as Map<String, dynamic>;

      final panel = data['contents']?['singleColumnMusicWatchNextResultsRenderer']
          ?['tabbedRenderer']?['watchNextTabbedResultsRenderer']?['tabs']?[0]
          ?['tabRenderer']?['content']?['musicQueueRenderer']?['content']
          ?['playlistPanelRenderer'];

      final rawItems = panel?['contents'] as List?;
      final items = <RecommendationItem>[];
      final seen = <String>{...?excludeVideoIds, ..._sessionPlayedVideoIds};
      if (videoId.isNotEmpty) seen.add(videoId);

      if (rawItems != null) {
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

      final batch = RecommendationBatch(
        items: items,
        continuationToken: continuationToken,
      );

      if (_radioCache.length >= _maxCacheSize) {
        _radioCache.remove(_radioCache.keys.first);
      }
      _radioCache[videoId] = batch;

      return batch;
    } catch (e) {
      debugPrint('[RecommendationService] Failed to fetch radio: $e');
      return const RecommendationBatch(items: []);
    }
  }

  /// Fetches the next paged batch of recommendations using a [continuationToken].
  static Future<RecommendationBatch> fetchContinuation(
    String continuationToken, {
    Set<String>? excludeVideoIds,
  }) async {
    try {
      final request = await _httpClient.postUrl(
        Uri.parse('https://music.youtube.com/youtubei/v1/next'),
      );
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');
      request.headers.set('Referer', 'https://music.youtube.com/');

      final body = jsonEncode({
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': '1.20260801.01.00',
            'hl': 'en',
            'gl': 'US',
          }
        },
        'continuation': continuationToken,
      });

      request.write(body);
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        return const RecommendationBatch(items: []);
      }

      final respText = await response.transform(utf8.decoder).join();
      final data = jsonDecode(respText) as Map<String, dynamic>;

      final panel = data['continuationContents']?['playlistPanelContinuation'];
      final rawItems = panel?['contents'] as List?;
      final items = <RecommendationItem>[];
      final seen = <String>{...?excludeVideoIds, ..._sessionPlayedVideoIds};

      if (rawItems != null) {
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

      String? nextContinuation;
      final nextConts = panel?['continuations'] as List?;
      if (nextConts != null && nextConts.isNotEmpty) {
        nextContinuation = nextConts[0]['nextContinuationData']?['continuation'] as String?;
      }

      return RecommendationBatch(
        items: items,
        continuationToken: nextContinuation,
      );
    } catch (e) {
      debugPrint('[RecommendationService] Failed to fetch continuation: $e');
      return const RecommendationBatch(items: []);
    }
  }

  /// Offline fallback: selects tracks from [allLibrarySongs] with artist/title affinity to [seed].
  static List<Song> getOfflineRecommendations(
    Song seed,
    List<Song> allLibrarySongs, {
    int count = 15,
    Set<String>? excludeSongIds,
  }) {
    final seen = <String>{seed.id, ...?excludeSongIds};
    final candidates = allLibrarySongs.where((s) => !seen.contains(s.id)).toList();
    if (candidates.isEmpty) return const [];

    final seedWords = seed.title.toLowerCase().split(RegExp(r'[\s\-_,]+')).where((w) => w.length > 2).toSet();

    candidates.sort((a, b) {
      var scoreA = 0;
      var scoreB = 0;

      final wordsA = a.title.toLowerCase().split(RegExp(r'[\s\-_,]+')).toSet();
      final wordsB = b.title.toLowerCase().split(RegExp(r'[\s\-_,]+')).toSet();

      scoreA += wordsA.intersection(seedWords).length * 3;
      scoreB += wordsB.intersection(seedWords).length * 3;

      return scoreB.compareTo(scoreA);
    });

    return candidates.take(count).toList();
  }
}
