import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'backup_audio_engine.dart';
import 'debug_log.dart';

/// Plays a live HLS stream on the desktop engine as one continuous stream.
///
/// The desktop player's mpv build has no HLS demuxer: it reads a live
/// playlist as a list of several hundred five-second files and reports each
/// one as a finished song, so a live stream "ended" every five seconds. This
/// serves the same stream on a loopback address instead: it follows the
/// playlist, and writes each new segment into one chunked response, which the
/// player sees as a single audio stream (YouTube's live audio segments are
/// plain ADTS AAC, so they join by concatenation). It ends the response when
/// the playlist ends or stops answering, which the player treats as the
/// stream's end, like a song.
///
/// Phones play the playlist natively and do not use this.
class LiveHlsProxy {
  LiveHlsProxy._(this._server, this._playlistUrl, this._poll, this._startBack,
      this._client);

  final HttpServer _server;
  final String _playlistUrl;
  final Duration _poll;
  final int _startBack;
  final http.Client _client;
  bool _stopped = false;

  static LiveHlsProxy? _current;

  /// Starts relaying [playlistUrl] and returns the local address to play.
  /// A relay that is already running is stopped first. [poll] is how often the
  /// playlist is read again, [startBack] how many segments behind the live
  /// edge playback starts (a few seconds of lead so it does not stall).
  static Future<Uri> serve(
    String playlistUrl, {
    Duration poll = const Duration(seconds: 4),
    int startBack = 2,
    http.Client? client,
  }) async {
    stop();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = LiveHlsProxy._(
      server,
      playlistUrl,
      poll,
      startBack,
      client ?? BackupAudioEngine.ipv4Client(),
    );
    _current = proxy;
    unawaited(proxy._listen());
    return Uri.parse('http://127.0.0.1:${server.port}/live.aac');
  }

  /// Stops the running relay, if any.
  static void stop() {
    _current?._stop();
    _current = null;
  }

  void _stop() {
    if (_stopped) return;
    _stopped = true;
    unawaited(_server.close(force: true));
    _client.close();
  }

  Future<void> _listen() async {
    try {
      await for (final request in _server) {
        unawaited(_stream(request));
      }
    } catch (_) {
      // The server was closed.
    }
  }

  Future<void> _stream(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType('audio', 'aac');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.bufferOutput = false;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }

    var gone = false;
    unawaited(response.done.then((_) => gone = true, onError: (_) => gone = true));

    int? next; // The next media sequence number to send.
    var failures = 0;
    var ended = false;
    while (!gone && !_stopped && !ended) {
      final list = await _fetchPlaylist();
      if (list == null) {
        if (++failures >= 6) {
          DebugLog.write('[live] Playlist stopped answering, ending the stream');
          break;
        }
        await Future<void>.delayed(_poll);
        continue;
      }
      failures = 0;
      final first = list.firstSequence;
      final count = list.segments.length;
      if (next == null || next < first) {
        // The first read, or playback fell behind the window: rejoin near the
        // live edge.
        next = math.max(first, first + count - _startBack);
      }
      for (var i = next - first; i < count && !gone && !_stopped; i++) {
        final bytes = await _fetchSegment(list.segments[i]);
        next = first + i + 1;
        if (bytes == null || gone || _stopped) continue;
        try {
          response.add(bytes);
          await response.flush();
        } catch (_) {
          gone = true;
        }
      }
      ended = list.ended;
      if (!ended) await Future<void>.delayed(_poll);
    }
    try {
      await response.close();
    } catch (_) {}
  }

  Future<_Playlist?> _fetchPlaylist() async {
    try {
      final res = await _client
          .get(Uri.parse(_playlistUrl))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      return _Playlist.parse(res.body, Uri.parse(_playlistUrl));
    } catch (_) {
      return null;
    }
  }

  Future<List<int>?> _fetchSegment(Uri uri) async {
    try {
      final res = await _client.get(uri).timeout(const Duration(seconds: 15));
      return res.statusCode == 200 ? res.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }
}

class _Playlist {
  _Playlist(this.firstSequence, this.segments, this.ended);

  final int firstSequence;
  final List<Uri> segments;
  final bool ended;

  /// Reads a media playlist. Segment lines may be relative to [base].
  static _Playlist parse(String text, Uri base) {
    var sequence = 0;
    var ended = false;
    final segments = <Uri>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        sequence = int.tryParse(line.substring(22)) ?? 0;
      } else if (line.startsWith('#EXT-X-ENDLIST')) {
        ended = true;
      } else if (!line.startsWith('#')) {
        segments.add(base.resolve(line));
      }
    }
    return _Playlist(sequence, segments, ended);
  }
}
