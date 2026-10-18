import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'backup_audio_engine.dart';
import 'debug_log.dart';

/// Hands a streamed song's picture to the video player over a loopback
/// address, so the app sees (and counts) every byte of it ([bytesUsed]) and
/// the request headers YouTube expects are added in one place.
///
/// The player sees one ordinary file with a known length and range support,
/// but each answer is a short window of it ([windowBytes]) and the player asks
/// again when it needs more, so what is fetched cannot run ahead of what is
/// played by more than a window. (Answering a whole range at once let the
/// socket buffers swallow the file on every jump.)
class VideoRelay {
  VideoRelay._(
    this._server,
    this._url,
    this._client,
    this._headers,
    this._relink,
  );

  final HttpServer _server;
  String _url;
  final HttpClient _client;
  Map<String, String> _headers;
  final Future<({String url, Map<String, String> headers})?> Function()?
      _relink;
  Future<bool>? _relinking;
  bool _stopped = false;

  /// The start of the file as far as it has arrived, and the file's length:
  /// the player re-reads the start (container header and index) at every jump,
  /// so keeping it makes that free. Filled as the bytes come in, since the
  /// player often leaves before the window ends.
  final BytesBuilder _head = BytesBuilder();
  int _headTotal = 0;
  String _headType = 'video/mp4';

  /// Bytes moved over the network for the current picture; 0 for each new one.
  static final ValueNotifier<int> bytesUsed = ValueNotifier<int>(0);

  /// How much of the file one answer carries (and one upstream read:
  /// YouTube throttles long unchunked reads).
  static const int windowBytes = 2 * 1024 * 1024;

  /// The least of the start worth answering from memory.
  static const int headMin = 256 * 1024;

  /// A window is sized to about this much of the link's speed, so a jump on a
  /// slow link does not leave seconds of unread data being fetched (the
  /// player leaves, the loopback socket swallows the whole window, and the
  /// upstream read goes on for nobody). Never over [windowBytes].
  @visibleForTesting
  static Duration windowTime = const Duration(seconds: 4);
  static const int _windowMin = 256 * 1024;
  int _window = windowBytes;

  /// How long a read may go without a single byte before it is cut. A phone
  /// moving between cells can leave a socket silent for minutes; cut, the
  /// player's reconnect asks for the rest at once.
  @visibleForTesting
  static Duration idleTimeout = const Duration(seconds: 8);

  static VideoRelay? _current;

  /// Starts relaying [url] (stopping any running relay) and returns the local
  /// address to play. [relink] is asked once for a new link when the first is
  /// refused (403 or 410); a link still refused after that fails the read.
  static Future<Uri> serve(
    String url, {
    Map<String, String> headers = const {},
    HttpClient? client,
    Future<({String url, Map<String, String> headers})?> Function()? relink,
  }) async {
    stop();
    bytesUsed.value = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = VideoRelay._(
      server,
      url,
      client ?? BackupAudioEngine.ipv4HttpClient(),
      headers,
      relink,
    );
    _current = relay;
    unawaited(relay._listen());
    return Uri.parse('http://127.0.0.1:${server.port}/video');
  }

  /// Stops the running relay, if any.
  static void stop() {
    final relay = _current;
    _current = null;
    relay?._stop();
  }

  void _stop() {
    if (_stopped) return;
    _stopped = true;
    DebugLog.write(
      '[video] relay closed, ${(bytesUsed.value / 1024).round()} KB over the '
      'network',
    );
    unawaited(_server.close(force: true));
    _client.close(force: true);
  }

  Future<void> _listen() async {
    try {
      await for (final req in _server) {
        unawaited(_handle(req));
      }
    } catch (e) {
      if (!_stopped) DebugLog.write('[video] relay stopped: $e');
    }
  }

  /// `bytes=a-b` or `bytes=a-`; null for no range or one this does not serve.
  static ({int start, int? end})? parseRange(String? header) {
    if (header == null) return null;
    final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
    if (m == null) return null;
    final end = m.group(2)!;
    return (
      start: int.parse(m.group(1)!),
      end: end.isEmpty ? null : int.parse(end),
    );
  }

  Future<HttpClientResponse> _open(int from, int to) async {
    var res = await _request(from, to);
    final denied = res.statusCode == HttpStatus.forbidden ||
        res.statusCode == HttpStatus.gone;
    if (denied && _relink != null) {
      await res.drain<void>();
      // One lookup serves every request that was refused at the same time.
      final relinked = await (_relinking ??= _relinkOnce());
      if (relinked) res = await _request(from, to);
    }
    return res;
  }

  Future<HttpClientResponse> _request(int from, int to) async {
    final req = await _client.getUrl(Uri.parse(_url));
    _headers.forEach(req.headers.set);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$to');
    return req.close().timeout(const Duration(seconds: 15));
  }

  Future<bool> _relinkOnce() async {
    try {
      final fresh = await _relink!();
      if (fresh == null) return false;
      _url = fresh.url;
      _headers = fresh.headers;
      DebugLog.write('[video] picture link was refused, using a new one');
      return true;
    } catch (e) {
      DebugLog.write('[video] could not get a new picture link: $e');
      return false;
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    var gone = false;
    var sent = 0;
    var from = 0;
    var to = -1;
    unawaited(res.done.then((_) {}, onError: (_) => gone = true));
    try {
      final range = parseRange(req.headers.value(HttpHeaders.rangeHeader));
      final pos = range?.start ?? 0;
      from = pos;
      // At most one window: the player asks again from where it ends.
      final want = range?.end == null
          ? pos + _window - 1
          : math.min(range!.end!, pos + _window - 1);
      final started = Stopwatch()..start();
      if (pos == 0 && _head.length >= headMin && want >= _head.length - 1) {
        final head = _head.toBytes();
        res.statusCode = HttpStatus.partialContent;
        res.headers
          ..set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..set(HttpHeaders.contentTypeHeader, _headType)
          ..set('content-range', 'bytes 0-${head.length - 1}/$_headTotal')
          ..contentLength = head.length;
        res.add(head);
        to = head.length - 1;
        sent = head.length;
        await res.flush();
        return;
      }
      final upstream = await _open(pos, want);
      if (upstream.statusCode != 200 && upstream.statusCode != 206) {
        await upstream.drain<void>();
        res.statusCode = HttpStatus.badGateway;
        return;
      }
      final int total;
      final contentRange = upstream.headers.value('content-range');
      final slash = contentRange?.lastIndexOf('/') ?? -1;
      if (upstream.statusCode == 206 && slash > 0) {
        total = int.tryParse(contentRange!.substring(slash + 1)) ?? 0;
      } else {
        total = upstream.contentLength > 0 ? upstream.contentLength : 0;
      }
      // A server that ignores Range sends the whole file as 200: usable only
      // from the start, and as it is.
      final wholeFile = upstream.statusCode == 200;
      if (total <= 0 || (wholeFile && pos > 0)) {
        await upstream.drain<void>();
        res.statusCode = HttpStatus.badGateway;
        return;
      }
      if (pos >= total) {
        await upstream.drain<void>();
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set('content-range', 'bytes */$total');
        return;
      }
      final last = wholeFile ? total - 1 : math.min(want, total - 1);
      to = last;
      res.statusCode = range == null && wholeFile
          ? HttpStatus.ok
          : HttpStatus.partialContent;
      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(
          HttpHeaders.contentTypeHeader,
          upstream.headers.value(HttpHeaders.contentTypeHeader) ?? 'video/mp4',
        )
        ..contentLength = last - pos + 1;
      if (res.statusCode == HttpStatus.partialContent) {
        res.headers.set('content-range', 'bytes $pos-$last/$total');
      }

      var at = pos;
      await for (final piece in upstream.timeout(idleTimeout)) {
        if (gone || _stopped) break;
        bytesUsed.value += piece.length;
        final room = last - at + 1;
        if (room <= 0) break;
        final out = piece.length > room ? piece.sublist(0, room) : piece;
        if (!wholeFile && at == _head.length && at < windowBytes) {
          _head.add(out.length > windowBytes - at ? out.sublist(0, windowBytes - at) : out);
          _headTotal = total;
          _headType =
              upstream.headers.value(HttpHeaders.contentTypeHeader) ?? 'video/mp4';
        }
        res.add(out);
        at += out.length;
        sent = at - pos;
        await res.flush();
      }
      // How long a window took says how big the next should be.
      final took = started.elapsedMilliseconds;
      if (at - pos == last - pos + 1 && sent >= _windowMin && took > 0) {
        _window = (sent * windowTime.inMilliseconds / took)
            .round()
            .clamp(_windowMin, windowBytes);
      }
    } catch (e) {
      // The player dropping a request (a seek) is normal.
      if (!gone && !_stopped) DebugLog.write('[video] relay read failed: $e');
    } finally {
      if (!_stopped) {
        DebugLog.write(
          '[video] relay bytes=$from-${to < 0 ? '?' : to}: sent '
          '${(sent / 1024).round()} KB (${(bytesUsed.value / 1024).round()} '
          'KB total)',
        );
      }
      try {
        await res.close();
      } catch (_) {}
    }
  }
}
