import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'debug_log.dart';

/// Lightweight pure-Dart YouTube Innertube client.
///
/// Bypasses the embedded Python runtime and native CLI overhead by requesting
/// direct audio streams using the unthrottled ANDROID_VR client context.
/// If direct resolution fails, callers fall back to the full yt-dlp engine.
class InnertubeService {
  InnertubeService._();

  static HttpClient? _httpClient;
  static HttpClient get _client => _httpClient ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  static final Map<String, HttpClientRequest> _activeRequests = {};

  /// Aborts any in-flight Innertube HTTP download for [videoId].
  static void cancelDownload(String videoId) {
    final req = _activeRequests.remove(videoId);
    if (req != null) {
      try {
        req.abort();
        DebugLog.write('[innertube] Aborted in-flight download for $videoId');
      } catch (_) {}
    }
  }

  /// Probes the YouTube Innertube player endpoint for direct audio streaming URLs.
  ///
  /// Returns the unencrypted direct URL for itag 140 (.m4a AAC) or itag 251 (.webm Opus),
  /// or null if the video requires cipher deciphering or BotGuard verification.
  static Future<String?> resolveAudioUrl(String videoId) async {
    try {
      final req = await _client.postUrl(Uri.parse('https://www.youtube.com/youtubei/v1/player'));
      req.headers.set('Content-Type', 'application/json');
      req.headers.set(
        'User-Agent',
        'Mozilla/5.0 (Linux; Android 10; Quest 2) AppleWebKit/537.36 (KHTML, like Gecko) OculusBrowser/15.0.0.0.22.280386052 SamsungBrowser/4.0 Chrome/89.0.4389.90 Mobile VR Safari/537.36',
      );
      req.headers.set('X-YouTube-Client-Name', '28');
      req.headers.set('X-YouTube-Client-Version', '1.35.32');

      final payload = jsonEncode({
        'context': {
          'client': {
            'clientName': 'ANDROID_VR',
            'clientVersion': '1.35.32',
            'deviceMake': 'Oculus',
            'deviceModel': 'Quest 2',
            'osName': 'Android',
            'osVersion': '10',
            'hl': 'en',
            'gl': 'US',
          }
        },
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
      });

      req.write(payload);
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        DebugLog.write('[innertube] Player endpoint returned HTTP ${res.statusCode} for $videoId');
        return null;
      }

      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final playability = json['playabilityStatus']?['status'];
      if (playability != 'OK') {
        DebugLog.write('[innertube] Non-OK playability status "$playability" for $videoId');
        return null;
      }

      final formats = json['streamingData']?['adaptiveFormats'] as List<dynamic>? ?? [];
      // Prefer itag 140 (128kbps AAC / m4a container), fallback to itag 251 (Opus)
      String? fallbackOpusUrl;
      for (final f in formats) {
        if (f is! Map<String, dynamic>) continue;
        final itag = f['itag'];
        final url = f['url'] as String?;
        final cipher = f['signatureCipher'] ?? f['cipher'];

        if (url != null && url.isNotEmpty && cipher == null) {
          if (itag == 140) {
            return url;
          }
          if (itag == 251) {
            fallbackOpusUrl ??= url;
          }
        }
      }

      return fallbackOpusUrl;
    } catch (e) {
      DebugLog.write('[innertube] resolveAudioUrl error for $videoId: $e');
      return null;
    }
  }

  /// Downloads direct audio stream for [videoId] to [destinationFile] using pure Dart HTTP.
  ///
  /// Returns true if the file was downloaded successfully and verified (> 50 KB).
  /// Returns false if direct extraction is blocked, prompting yt-dlp fallback.
  static Future<bool> downloadAudioDirect(
    String videoId,
    File destinationFile, {
    void Function(int received, int total)? onProgress,
  }) async {
    final directUrl = await resolveAudioUrl(videoId);
    if (directUrl == null) {
      return false;
    }

    final tempFile = File('${destinationFile.path}.part');
    IOSink? sink;
    HttpClientRequest? req;

    try {
      DebugLog.write('[innertube] Direct downloading $videoId from googlevideo...');
      req = await _client.getUrl(Uri.parse(directUrl));
      _activeRequests[videoId] = req;

      req.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');
      final res = await req.close().timeout(const Duration(seconds: 15));

      if (res.statusCode != 200 && res.statusCode != 206) {
        DebugLog.write('[innertube] Googlevideo stream returned HTTP ${res.statusCode} for $videoId');
        return false;
      }

      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      sink = tempFile.openWrite();
      final contentLength = res.contentLength;
      int received = 0;

      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, contentLength);
      }

      await sink.flush();
      await sink.close();
      sink = null;

      final downloadedLength = await tempFile.length();
      if (downloadedLength < 50 * 1024) {
        DebugLog.write('[innertube] Downloaded payload too small ($downloadedLength bytes) for $videoId');
        if (await tempFile.exists()) await tempFile.delete();
        return false;
      }

      if (await destinationFile.exists()) {
        await destinationFile.delete();
      }
      await tempFile.rename(destinationFile.path);
      DebugLog.write('[innertube] Direct download succeeded for $videoId (${(downloadedLength / 1024).round()} KB)');
      return true;
    } catch (e) {
      DebugLog.write('[innertube] Direct stream download failed for $videoId: $e');
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      return false;
    } finally {
      _activeRequests.remove(videoId);
    }
  }
}
