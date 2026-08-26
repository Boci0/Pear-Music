import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'innertube_player_service.dart';
import 'stream_cache_manager.dart';

/// Embedded localhost HTTP proxy that serves audio streams to ExoPlayer / JustAudio
/// on 127.0.0.1, eliminating HTTP 403 Forbidden errors, handling Range/HEAD probes,
/// and streaming without competing connection races.
class StreamProxyService {
  static HttpServer? _server;
  static int? _port;
  static final HttpClient _proxyClient = HttpClient()
    ..idleTimeout = const Duration(seconds: 15)
    ..connectionTimeout = const Duration(seconds: 8)
    ..badCertificateCallback = ((cert, host, port) => true);

  /// Initializes and binds the loopback proxy server if not already running.
  static Future<int> ensureStarted() async {
    if (_server != null && _port != null) return _port!;

    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      debugPrint('[StreamProxyService] Started audio proxy on port ' + _port.toString());

      _server!.listen(_handleRequest, onError: (e) {
        debugPrint('[StreamProxyService] Server socket error: ' + e.toString());
      });

      return _port!;
    } catch (e) {
      debugPrint('[StreamProxyService] Failed to bind proxy server: ' + e.toString());
      return 0;
    }
  }

  /// Returns the localhost stream URI for a videoId.
  static Future<Uri?> getStreamProxyUri(String videoId) async {
    final port = await ensureStarted();
    if (port == 0) return null;
    return Uri.parse('http://127.0.0.1:' + port.toString() + '/stream/' + videoId);
  }

  static Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    if (!path.startsWith('/stream/')) {
      try {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      } catch (_) {}
      return;
    }

    final videoId = path.replaceFirst('/stream/', '').trim();
    if (videoId.isEmpty) {
      try {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
      } catch (_) {}
      return;
    }

    try {
      // Step 1: If fully cached, serve from local file instantly
      final cachedFile = await StreamCacheManager.getCachedFile(videoId);
      if (cachedFile != null && await cachedFile.exists()) {
        await _serveLocalFile(request, cachedFile);
        return;
      }

      // Step 1.5: If in-flight download is running, await it briefly
      final inFlight = StreamCacheManager.getInFlightDownload(videoId);
      if (inFlight != null) {
        try {
          final file = await inFlight.timeout(const Duration(seconds: 4));
          if (file != null && await file.exists()) {
            await _serveLocalFile(request, file);
            return;
          }
        } catch (_) {}
      }

      // Step 2: Resolve stream URL via Innertube Player Service
      var streamInfo = await InnertubePlayerService.resolveAudioStream(videoId);
      if (streamInfo != null && streamInfo.url.startsWith('http')) {
        final success = await _proxyRemoteUrl(request, streamInfo.url, videoId, streamInfo);
        if (success) return;
      }

      // Step 3: Fallback stream URI resolution
      final fallbackUri = await StreamCacheManager.resolveStreamUri(videoId);
      if (fallbackUri != null) {
        final success = await _proxyRemoteUrl(request, fallbackUri.toString(), videoId, null);
        if (success) return;
      }

      try {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      } catch (_) {}
    } catch (e) {
      debugPrint('[StreamProxyService] Error handling /stream/' + videoId + ': ' + e.toString());
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  static Future<void> _serveLocalFile(HttpRequest request, File file) async {
    try {
      final fileSize = await file.length();
      final ext = p.extension(file.path).toLowerCase();
      final mimeType = ext.contains('webm') ? 'audio/webm' : 'audio/mp4';

      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      if (request.method == 'HEAD') {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set(HttpHeaders.contentTypeHeader, mimeType);
        request.response.headers.set(HttpHeaders.contentLengthHeader, fileSize);
        await request.response.close();
        return;
      }

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
        if (match != null) {
          final start = int.parse(match.group(1)!);
          final endStr = match.group(2);
          final end = (endStr != null && endStr.isNotEmpty)
              ? int.parse(endStr)
              : fileSize - 1;

          final contentLength = end - start + 1;
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(HttpHeaders.contentTypeHeader, mimeType);
          request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes ' + start.toString() + '-' + end.toString() + '/' + fileSize.toString(),
          );
          request.response.headers.set(HttpHeaders.contentLengthHeader, contentLength);

          final stream = file.openRead(start, end + 1);
          await request.response.addStream(stream);
          await request.response.close();
          return;
        }
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set(HttpHeaders.contentTypeHeader, mimeType);
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(HttpHeaders.contentLengthHeader, fileSize);
      await request.response.addStream(file.openRead());
      await request.response.close();
    } catch (_) {
      // Client closed connection during stream playback (normal on pause/seek/skip)
    }
  }

  static Future<bool> _proxyRemoteUrl(
    HttpRequest request,
    String targetUrl,
    String videoId,
    InnertubeAudioStream? streamInfo,
  ) async {
    try {
      final isHead = request.method == 'HEAD';
      final upstreamReq = isHead
          ? await _proxyClient.headUrl(Uri.parse(targetUrl))
          : await _proxyClient.getUrl(Uri.parse(targetUrl));

      upstreamReq.headers.set(
        'User-Agent',
        'com.google.android.apps.youtube.music/6.42.52 (Linux; U; Android 14)',
      );
      upstreamReq.headers.set('Referer', 'https://music.youtube.com/');

      final clientRange = request.headers.value(HttpHeaders.rangeHeader);
      if (clientRange != null) {
        upstreamReq.headers.set(HttpHeaders.rangeHeader, clientRange);
      }

      final upstreamResp = await upstreamReq.close().timeout(const Duration(seconds: 8));
      var statusCode = upstreamResp.statusCode;
      if (statusCode == HttpStatus.forbidden || statusCode == HttpStatus.unauthorized) {
        StreamCacheManager.invalidateStreamUrl(videoId);
        return false;
      }

      final totalLength = streamInfo?.contentLength ?? upstreamResp.contentLength;

      // Normalize HTTP 200 with Range header into HTTP 206 Partial Content for ExoPlayer
      if (statusCode == HttpStatus.ok && clientRange != null && clientRange.startsWith('bytes=')) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(clientRange);
        if (match != null) {
          final start = int.parse(match.group(1)!);
          final endStr = match.group(2);
          final end = (endStr != null && endStr.isNotEmpty)
              ? int.parse(endStr)
              : (totalLength > 0 ? totalLength - 1 : upstreamResp.contentLength - 1);
          if (end >= start) {
            statusCode = HttpStatus.partialContent;
            final totalStr = totalLength > 0 ? totalLength.toString() : "*";
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes ' + start.toString() + '-' + end.toString() + '/' + totalStr,
            );
          }
        }
      }

      request.response.statusCode = statusCode;

      upstreamResp.headers.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower == HttpHeaders.contentTypeHeader ||
            lower == HttpHeaders.contentLengthHeader ||
            lower == HttpHeaders.contentRangeHeader ||
            lower == HttpHeaders.acceptRangesHeader) {
          for (final v in values) {
            request.response.headers.add(name, v);
          }
        }
      });

      if (request.response.headers.value(HttpHeaders.acceptRangesHeader) == null) {
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      }
      if (streamInfo != null && request.response.headers.value(HttpHeaders.contentTypeHeader) == null) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, streamInfo.mimeType);
      }

      if (isHead) {
        await request.response.close();
        return true;
      }

      await request.response.addStream(upstreamResp);
      await request.response.close();
      return true;
    } catch (_) {
      // Client closed connection during track change or seek (normal lifecycle)
      return true;
    }
  }

  /// Closes the proxy server.
  static Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = null;
  }
}
