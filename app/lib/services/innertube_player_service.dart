import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Represents a resolved audio stream format from YouTube Innertube.
class InnertubeAudioStream {
  final String url;
  final int itag;
  final String mimeType;
  final int bitrate;
  final int contentLength;
  final String container;

  const InnertubeAudioStream({
    required this.url,
    required this.itag,
    required this.mimeType,
    required this.bitrate,
    required this.contentLength,
    required this.container,
  });
}

/// Service that queries YouTube's Innertube Player API using mobile client contexts
/// (ANDROID_MUSIC, IOS, TVHTML5) to extract direct, unscrambled audio stream URLs.
class InnertubePlayerService {
  static final HttpClient _httpClient = HttpClient();
  static final Map<String, ({InnertubeAudioStream stream, DateTime expiresAt})> _streamCache = {};

  static const List<Map<String, String>> _clientContexts = [
    {
      'clientName': 'ANDROID_MUSIC',
      'clientVersion': '6.42.52',
      'userAgent': 'com.google.android.apps.youtube.music/6.42.52 (Linux; U; Android 14)',
      'referer': 'https://music.youtube.com/',
      'endpoint': 'https://music.youtube.com/youtubei/v1/player',
    },
    {
      'clientName': 'IOS',
      'clientVersion': '19.09.4',
      'userAgent': 'com.google.ios.youtube/19.09.4 (iPhone14,3; U; CPU iOS 17_4 like Mac OS X; en_US)',
      'referer': 'https://www.youtube.com/',
      'endpoint': 'https://www.youtube.com/youtubei/v1/player',
    },
    {
      'clientName': 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
      'clientVersion': '2.0',
      'userAgent': 'Mozilla/5.0 (SMART-TV; Linux; Tizen 5.0) AppleWebKit/538.1',
      'referer': 'https://www.youtube.com/',
      'endpoint': 'https://www.youtube.com/youtubei/v1/player',
    },
  ];

  /// Resolves the highest quality audio stream for a given [videoId].
  static Future<InnertubeAudioStream?> resolveAudioStream(String videoId) async {
    final cached = _streamCache[videoId];
    if (cached != null) {
      if (DateTime.now().isBefore(cached.expiresAt)) {
        return cached.stream;
      }
      _streamCache.remove(videoId);
    }

    // Method 1: Multi-client Innertube Player API (Fast ~150-250ms, direct unscrambled URLs)
    for (final ctx in _clientContexts) {
      try {
        final request = await _httpClient.postUrl(Uri.parse(ctx['endpoint']!));
        request.headers.set('Content-Type', 'application/json');
        request.headers.set('User-Agent', ctx['userAgent']!);
        request.headers.set('Referer', ctx['referer']!);

        final body = jsonEncode({
          'context': {
            'client': {
              'clientName': ctx['clientName'],
              'clientVersion': ctx['clientVersion'],
              'hl': 'en',
              'gl': 'US',
            }
          },
          'videoId': videoId,
          'playbackContext': {
            'contentPlaybackContext': {
              'html5Preference': 'HTML5_PREF_WANTS',
            }
          }
        });

        request.write(body);
        final response = await request.close().timeout(const Duration(seconds: 4));
        if (response.statusCode != 200) continue;

        final respText = await response.transform(utf8.decoder).join();
        final data = jsonDecode(respText) as Map<String, dynamic>;

        final playability = data['playabilityStatus']?['status'] as String?;
        if (playability != null && playability != 'OK') {
          continue;
        }

        final formats = data['streamingData']?['adaptiveFormats'] as List?;
        if (formats == null || formats.isEmpty) continue;

        InnertubeAudioStream? bestFormat;
        for (final f in formats) {
          final mime = f['mimeType'] as String? ?? '';
          if (!mime.startsWith('audio/')) continue;
          final rawUrl = f['url'] as String?;
          if (rawUrl == null || rawUrl.isEmpty) continue; // Skip ciphered formats

          final itag = f['itag'] as int? ?? 0;
          final bitrate = f['bitrate'] as int? ?? 0;
          final contentLength = int.tryParse(f['contentLength']?.toString() ?? '0') ?? 0;
          final container = mime.contains('mp4') ? 'm4a' : 'webm';

          final stream = InnertubeAudioStream(
            url: rawUrl,
            itag: itag,
            mimeType: mime,
            bitrate: bitrate,
            contentLength: contentLength,
            container: container,
          );

          // Prefer m4a (AAC itag 140) or highest bitrate audio
          if (bestFormat == null ||
              (stream.container == 'm4a' && bestFormat.container != 'm4a') ||
              (stream.container == bestFormat.container && stream.bitrate > bestFormat.bitrate)) {
            bestFormat = stream;
          }
        }

        if (bestFormat != null) {
          _streamCache[videoId] = (
            stream: bestFormat,
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          );
          return bestFormat;
        }
      } catch (e) {
        debugPrint('[InnertubePlayerService] client  failed: ');
      }
    }

    return null;
  }

  /// Checks if a stream URL is in cache and valid.
  static bool hasCachedStream(String videoId) {
    final entry = _streamCache[videoId];
    if (entry == null) return false;
    return DateTime.now().isBefore(entry.expiresAt);
  }
}
