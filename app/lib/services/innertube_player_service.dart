import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'debug_log.dart';

/// Representation of an audio stream resolved via Innertube.
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

  bool get isHighQuality => bitrate >= 128000;
}

/// High-speed direct client for YouTube Music / Innertube API.
/// Bypasses heavy process overhead and directly queries Android Innertube endpoints for
/// unscrambled audio stream URLs.
class InnertubePlayerService {
  static final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..idleTimeout = const Duration(seconds: 6);

  static final Map<String, ({InnertubeAudioStream stream, DateTime expiresAt})> _streamCache = {};
  static final Map<String, Completer<InnertubeAudioStream?>> _inFlightResolutions = {};

  /// Invalidate cached stream for a given video ID
  static void invalidateCache(String videoId) {
    _streamCache.remove(videoId);
  }

  static const List<Map<String, dynamic>> _clientContexts = [
    {
      'clientName': 'ANDROID_VR',
      'clientVersion': '1.56.21',
      'userAgent': 'com.google.android.apps.youtube.vr.oculus/1.56.21 (Linux; U; Android 12; Oculus Quest 2)',
      'referer': 'https://www.youtube.com/',
      'endpoint': 'https://www.youtube.com/youtubei/v1/player',
      'payload': {
        'client': {
          'clientName': 'ANDROID_VR',
          'clientVersion': '1.56.21',
          'androidSdkVersion': 32,
          'hl': 'en',
          'gl': 'US',
        },
      },
    },
    {
      'clientName': 'ANDROID_MUSIC',
      'clientVersion': '6.42.52',
      'userAgent': 'com.google.android.apps.youtube.music/6.42.52 (Linux; U; Android 14; en_US)',
      'referer': 'https://music.youtube.com/',
      'endpoint': 'https://music.youtube.com/youtubei/v1/player',
      'payload': {
        'client': {
          'clientName': 'ANDROID_MUSIC',
          'clientVersion': '6.42.52',
          'androidSdkVersion': 34,
          'hl': 'en',
          'gl': 'US',
        },
      },
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

    if (_inFlightResolutions.containsKey(videoId)) {
      return await _inFlightResolutions[videoId]!.future;
    }

    final completer = Completer<InnertubeAudioStream?>();
    _inFlightResolutions[videoId] = completer;

    try {
      // Method 1: Fast direct Innertube Player API (~150-500ms direct unscrambled URLs)
      for (final ctx in _clientContexts) {
        try {
          final endpoint = ctx['endpoint'] as String;
          final userAgent = ctx['userAgent'] as String;
          final referer = ctx['referer'] as String;
          final clientContext = ctx['payload'] as Map<String, dynamic>;

          final request = await _httpClient.postUrl(Uri.parse(endpoint));
          request.headers.set('Content-Type', 'application/json');
          request.headers.set('User-Agent', userAgent);
          request.headers.set('Referer', referer);

          final body = jsonEncode({
            'context': clientContext,
            'videoId': videoId,
            'playbackContext': {
              'contentPlaybackContext': {
                'html5Preference': 'HTML5_PREF_WANTS',
              }
            }
          });

          request.add(utf8.encode(body));
          final response = await request.close().timeout(const Duration(milliseconds: 2800));
          if (response.statusCode != 200) continue;

          final respText = await response.transform(utf8.decoder).join();
          final data = jsonDecode(respText) as Map<String, dynamic>;

          final playabilityStatus = data['playabilityStatus']?['status'] as String?;
          if (playabilityStatus != 'OK') {
            continue;
          }

          final streamingData = data['streamingData'] as Map<String, dynamic>?;
          if (streamingData == null) continue;

          final formats = (streamingData['adaptiveFormats'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();

          InnertubeAudioStream? bestFormat;

          for (final format in formats) {
            final mime = format['mimeType'] as String? ?? '';
            if (!mime.startsWith('audio/')) continue;

            final rawUrl = format['url'] as String?;
            if (rawUrl == null || rawUrl.isEmpty) continue;

            final itag = format['itag'] as int? ?? 0;
            final bitrate = format['bitrate'] as int? ?? 0;
            final contentLength = int.tryParse(format['contentLength']?.toString() ?? '0') ?? 0;
            final container = mime.contains('mp4') ? 'm4a' : 'webm';

            final stream = InnertubeAudioStream(
              url: rawUrl,
              itag: itag,
              mimeType: mime,
              bitrate: bitrate,
              contentLength: contentLength,
              container: container,
            );

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
            DebugLog.write('[stream] Innertube direct resolution SUCCESS: $videoId (${bestFormat.bitrate ~/ 1000}kbps ${bestFormat.container}) via ${ctx['clientName']}');
            completer.complete(bestFormat);
            return bestFormat;
          }
        } catch (_) {}
      }

      completer.complete(null);
      return null;
    } catch (e) {
      if (!completer.isCompleted) completer.complete(null);
      return null;
    } finally {
      _inFlightResolutions.remove(videoId);
    }
  }

  /// Checks if a stream URL is in cache and valid.
  static bool hasCachedStream(String videoId) {
    final entry = _streamCache[videoId];
    if (entry == null) return false;
    return DateTime.now().isBefore(entry.expiresAt);
  }
}
