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

/// Service that queries YouTube's Innertube Player API using mobile and TV client contexts
/// (ANDROID_MUSIC, IOS, ANDROID_VR, TVHTML5) and Piped fallback to extract direct,
/// unscrambled audio stream URLs.
class InnertubePlayerService {
  static final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 10);

  static final Map<String, ({InnertubeAudioStream stream, DateTime expiresAt})> _streamCache = {};

  static const List<Map<String, dynamic>> _clientContexts = [
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
    {
      'clientName': 'IOS',
      'clientVersion': '19.29.1',
      'userAgent': 'com.google.ios.youtube/19.29.1 (iPhone14,3; U; CPU iOS 17_5 like Mac OS X; en_US)',
      'referer': 'https://www.youtube.com/',
      'endpoint': 'https://www.youtube.com/youtubei/v1/player',
      'payload': {
        'client': {
          'clientName': 'IOS',
          'clientVersion': '19.29.1',
          'deviceMake': 'Apple',
          'deviceModel': 'iPhone14,3',
          'osName': 'iOS',
          'osVersion': '17.5.1.21F90',
          'hl': 'en',
          'gl': 'US',
        },
      },
    },
    {
      'clientName': 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
      'clientVersion': '2.0',
      'userAgent': 'Mozilla/5.0 (SMART-TV; Linux; Tizen 5.0) AppleWebKit/538.1',
      'referer': 'https://www.youtube.com/',
      'endpoint': 'https://www.youtube.com/youtubei/v1/player',
      'payload': {
        'client': {
          'clientName': 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
          'clientVersion': '2.0',
          'hl': 'en',
          'gl': 'US',
        },
        'thirdParty': {
          'embedUrl': 'https://www.youtube.com',
        },
      },
    },
  ];

  static const List<String> _pipedInstances = [
    'https://pipedapi.kavin.rocks',
    'https://api.piped.private.coffee',
    'https://pipedapi.leptons.xyz',
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

    // Method 1: Multi-client Innertube Player API (~150-250ms direct unscrambled URLs)
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
        debugPrint('[InnertubePlayerService] client ' + (ctx['clientName'] as String) + ' failed: ' + e.toString());
      }
    }

    // Method 2: Piped cloud API fallback (~200ms)
    for (final instance in _pipedInstances) {
      try {
        final uri = Uri.parse(instance + '/streams/' + videoId);
        final req = await _httpClient.getUrl(uri);
        req.headers.set('User-Agent', 'Mozilla/5.0');
        final resp = await req.close().timeout(const Duration(seconds: 4));
        if (resp.statusCode == 200) {
          final text = await resp.transform(utf8.decoder).join();
          final data = jsonDecode(text) as Map<String, dynamic>;
          final audioStreams = data['audioStreams'] as List?;
          if (audioStreams != null && audioStreams.isNotEmpty) {
            final first = audioStreams.first as Map<String, dynamic>;
            final streamUrl = first['url'] as String?;
            if (streamUrl != null && streamUrl.startsWith('http')) {
              final stream = InnertubeAudioStream(
                url: streamUrl,
                itag: first['itag'] as int? ?? 140,
                mimeType: first['mimeType'] as String? ?? 'audio/mp4',
                bitrate: first['bitrate'] as int? ?? 128000,
                contentLength: first['contentLength'] as int? ?? 0,
                container: (first['format'] as String? ?? 'M4A').toLowerCase() == 'webm' ? 'webm' : 'm4a',
              );
              _streamCache[videoId] = (
                stream: stream,
                expiresAt: DateTime.now().add(const Duration(hours: 2)),
              );
              return stream;
            }
          }
        }
      } catch (e) {
        debugPrint('[InnertubePlayerService] Piped fallback failed: ' + e.toString());
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
