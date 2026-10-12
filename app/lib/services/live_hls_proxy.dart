import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

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
/// The audio is handed over at the speed it plays, not in segment-sized
/// bursts: the player's network timeout is five seconds and a live segment
/// only exists every five, so a burst-then-silence feed was cut off as a dead
/// connection after about half a minute.
///
/// Phones use it too: their player would read the playlist uncompressed, which
/// is 900 KB every few seconds, about 13 MB a minute of mobile data.
class LiveHlsProxy {
  LiveHlsProxy._(this._server, this._playlistUrl, this._poll, this._startBack,
      this._client, this._tick, this._refresh);

  final HttpServer _server;

  /// Replaced when [_refresh] hands over a new link.
  String _playlistUrl;
  final Future<String?> Function()? _refresh;
  int _refreshes = 0;
  bool _relinked = false;

  /// Most new links one stream may ask for, so a link YouTube keeps refusing
  /// cannot turn into a stream of lookups against it.
  static const int _maxRefreshes = 10;
  final Duration _poll;
  final int _startBack;
  final HttpClient _client;
  final Duration _tick;
  bool _stopped = false;

  /// Playlist reads so far, for the log: each is ~900 KB of text that goes
  /// over the wire gzip-compressed (about 12 KB), which is why polling it
  /// every few seconds costs about 3 KB/s next to the audio's 16 KB/s.
  int _playlistReads = 0;

  /// Bytes this relay has moved over the network for the current live stream
  /// (audio plus the compressed playlist reads), shown next to the LIVE label.
  /// Starts again at 0 with each stream.
  static final ValueNotifier<int> bytesUsed = ValueNotifier<int>(0);

  /// How much history the stream keeps, in seconds, as of the last playlist
  /// read (YouTube's DVR window, an hour for most broadcasts, a minute or two
  /// for some). 0 until the first read. This is how far back a stream can be
  /// rewound.
  static final ValueNotifier<double> windowSeconds = ValueNotifier<double>(0);

  /// How far behind the newest audio a stream opened without a `back` starts:
  /// [startBack] segments of five seconds.
  static const double defaultLead = 10;

  static LiveHlsProxy? _current;

  /// The running relay's address, starting [behind] seconds behind the newest
  /// audio ([defaultLead] when null). Null when no relay is running. Opening
  /// it again is how a stream is rewound or returned to live.
  static Uri? address({double? behind}) => _current?._address(behind);

  Uri _address(double? behind) => Uri.parse(
        'http://127.0.0.1:${_server.port}/live.aac'
        '${behind == null ? '' : '?back=${behind.round()}'}',
      );

  /// Segments held for sending. Fetching waits while this many are queued, so
  /// a paused player (or a rewound start with a long backlog) neither makes
  /// the relay grow without bound nor makes it skip audio.
  static const int _maxQueued = 12;

  /// Starts relaying [playlistUrl] and returns the local address to play.
  /// A relay that is already running is stopped first. [poll] is how often the
  /// playlist is read again, [startBack] how many segments behind the live
  /// edge playback starts (a few seconds of lead so it does not stall), and
  /// [tick] the spacing of the pieces the audio is handed over in. [refresh]
  /// looks the stream's link up again: the relay asks for it when the current
  /// one keeps being refused (it is tied to the connection it was made on, so
  /// a phone changing between Wi-Fi and mobile data invalidates it).
  static Future<Uri> serve(
    String playlistUrl, {
    Duration poll = const Duration(seconds: 4),
    int startBack = 2,
    Duration tick = const Duration(milliseconds: 100),
    HttpClient? client,
    Future<String?> Function()? refresh,
  }) async {
    stop();
    bytesUsed.value = 0;
    windowSeconds.value = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = LiveHlsProxy._(
      server,
      playlistUrl,
      poll,
      startBack,
      (client ?? BackupAudioEngine.ipv4HttpClient())..autoUncompress = false,
      tick,
      refresh,
    );
    _current = proxy;
    unawaited(proxy._listen());
    return proxy._address(null);
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
    _client.close(force: true);
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
    bool halted() => gone || _stopped;

    final queue = Queue<_Piece>();
    var producing = true;
    final back = double.tryParse(request.uri.queryParameters['back'] ?? '');
    final producer =
        _collect(queue, halted, back).whenComplete(() => producing = false);

    // The first piece goes out at once so the player can start and becomes
    // its lead; after that the audio is kept exactly that far ahead of the
    // clock, so the player's buffer neither drains nor grows.
    final pace = _Pace();
    final started = Stopwatch()..start();
    var sent = 0;
    while (!halted()) {
      if (queue.isEmpty) {
        if (!producing) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        continue;
      }
      final piece = queue.removeFirst();
      if (!await _send(response, piece, pace, halted)) {
        gone = true;
        break;
      }
      sent += piece.bytes.length;
    }
    DebugLog.write(
      '[live] Relay finished after ${started.elapsed.inSeconds}s, '
      '${(sent / 1024).round()} KB of audio sent, $_playlistReads playlist '
      'reads, ${(bytesUsed.value / 1024).round()} KB over the network, '
      'player gone: $gone',
    );
    try {
      await response.close();
    } catch (_) {}
    await producer;
  }

  /// Hands [piece] to the player in [_tick]-sized slices, each held back
  /// until the audio sent is no more than [pace]'s lead ahead of the clock.
  /// False when the player has gone.
  Future<bool> _send(
    HttpResponse response,
    _Piece piece,
    _Pace pace,
    bool Function() halted,
  ) async {
    final bytes = piece.bytes;
    final slices =
        math.max(1, (piece.seconds * 1000 / _tick.inMilliseconds).round());
    final size = (bytes.length / slices).ceil();
    final seconds = piece.seconds / slices;
    if (pace.sent == 0) {
      // The clock starts with the first audio, not with the playlist reads.
      pace.lead = piece.seconds;
      pace.clock
        ..reset()
        ..start();
    }
    try {
      for (var i = 0; i < slices && !halted(); i++) {
        final from = i * size;
        if (from >= bytes.length) break;
        while (!halted() &&
            pace.sent > pace.lead + pace.clock.elapsedMilliseconds / 1000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        response.add(bytes.sublist(from, math.min(bytes.length, from + size)));
        await response.flush();
        pace.sent += seconds;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Follows the playlist and queues each new segment. Ends with the
  /// playlist, when it stops answering, or when the relay is [halted].
  ///
  /// [back] is how many seconds behind the newest audio the first segment is
  /// taken from; null starts [_startBack] segments behind, and a value past
  /// the window starts at its oldest segment.
  Future<void> _collect(
    Queue<_Piece> queue,
    bool Function() halted,
    double? back,
  ) async {
    int? next; // The next media sequence number to fetch.
    // Reads that failed in a row, playlist or segment. Three in a row ask for
    // a new link, six end the stream.
    var failures = 0;
    while (!halted()) {
      final list = await _fetchPlaylist();
      if (list == null) {
        if (!await _recover(++failures)) return;
        if (_relinked) {
          _relinked = false;
          next = null;
        }
        await Future<void>.delayed(_poll);
        continue;
      }
      final first = list.firstSequence;
      final count = list.segments.length;
      if (next == null && back != null) {
        // Walk back from the newest segment until [back] seconds are covered.
        var covered = 0.0;
        var i = count;
        while (i > 0 && covered < back) {
          covered += list.seconds[--i];
        }
        next = first + i;
        back = null; // Only the start is rewound; a new link rejoins the edge.
      } else if (next == null || next < first) {
        // The first read, or playback fell behind the window: rejoin near the
        // live edge.
        next = math.max(first, first + count - _startBack);
      }
      // A playlist that answers with nothing new is a healthy stream.
      if (next >= first + count) failures = 0;
      for (var i = next - first; i < count && !halted(); i++) {
        // Never fetch further ahead than the queue holds: a stream rewound by
        // half an hour would otherwise race through the backlog and keep only
        // the newest segments, ending up a minute behind with the data spent.
        while (queue.length >= _maxQueued && !halted()) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        if (halted()) break;
        final bytes = await _fetchSegment(list.segments[i]);
        next = first + i + 1;
        if (halted()) break;
        if (bytes == null) {
          if (!await _recover(++failures)) return;
          if (_relinked) {
            _relinked = false;
            next = null;
            break;
          }
          continue;
        }
        failures = 0;
        queue.add(_Piece(bytes, list.seconds[i]));
      }
      if (list.ended) return;
      await Future<void>.delayed(_poll);
    }
  }

  /// Decides what to do after the [failures]th failed read in a row: false
  /// when the stream should end. At the third it asks for a new link, which
  /// is what a link that was refused (expired, or made on another network)
  /// needs; [_relinked] tells the caller to rejoin the live edge with it.
  Future<bool> _recover(int failures) async {
    if (failures >= 6) {
      DebugLog.write('[live] Playlist stopped answering, ending the stream');
      return false;
    }
    final refresh = _refresh;
    if (failures == 3 && refresh != null && _refreshes < _maxRefreshes) {
      _refreshes++;
      final url = await refresh();
      if (url != null) {
        _playlistUrl = url;
        _relinked = true;
        DebugLog.write('[live] Link refused or silent, using a new one');
      } else {
        DebugLog.write('[live] Link refused or silent and no new one found');
      }
    }
    return true;
  }

  Future<_Playlist?> _fetchPlaylist() async {
    final uri = Uri.parse(_playlistUrl);
    final bytes = await _get(uri);
    if (bytes == null) return null;
    _playlistReads++;
    try {
      final list =
          _Playlist.parse(utf8.decode(bytes, allowMalformed: true), uri);
      windowSeconds.value = list.seconds.fold(0.0, (sum, s) => sum + s);
      return list;
    } catch (e) {
      DebugLog.write('[live] playlist could not be parsed: $e');
      return null;
    }
  }

  Future<List<int>?> _fetchSegment(Uri uri) => _get(uri);

  /// Reads [uri] and counts what crossed the network. gzip is asked for and
  /// undone here: the client's own decompression would hide the compressed
  /// size, which is what a live playlist (900 KB of text) costs to read.
  Future<List<int>?> _get(Uri uri) async {
    try {
      final request =
          await _client.getUrl(uri).timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        // Host only: the path of a YouTube link carries its signature.
        DebugLog.write('[live] HTTP ${response.statusCode} from ${uri.host}');
        await response.drain<void>();
        return null;
      }
      final body = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        body.add(chunk);
      }
      final wire = body.takeBytes();
      bytesUsed.value += wire.length;
      final gzipped =
          response.headers.value(HttpHeaders.contentEncodingHeader) == 'gzip';
      return gzipped ? gzip.decode(wire) : wire;
    } catch (e) {
      if (!_stopped) DebugLog.write('[live] Read from ${uri.host} failed: ${e.runtimeType}');
      return null;
    }
  }
}

/// How far audio has been handed over against the wall clock.
class _Pace {
  final Stopwatch clock = Stopwatch()..start();

  /// Seconds of audio sent ahead of the clock, set by the first piece.
  double lead = 0;

  /// Seconds of audio handed over so far.
  double sent = 0;
}

/// One fetched segment and how long it plays for.
class _Piece {
  _Piece(this.bytes, this.seconds);

  final List<int> bytes;
  final double seconds;
}

class _Playlist {
  _Playlist(this.firstSequence, this.segments, this.seconds, this.ended);

  final int firstSequence;
  final List<Uri> segments;

  /// The play length of each of [segments].
  final List<double> seconds;
  final bool ended;

  /// Reads a media playlist. Segment lines may be relative to [base].
  static _Playlist parse(String text, Uri base) {
    var sequence = 0;
    var ended = false;
    var pending = 5.0;
    final segments = <Uri>[];
    final seconds = <double>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        sequence = int.tryParse(line.substring(22)) ?? 0;
      } else if (line.startsWith('#EXTINF:')) {
        final value = line.substring(8).split(',').first;
        pending = double.tryParse(value) ?? 5.0;
      } else if (line.startsWith('#EXT-X-ENDLIST')) {
        ended = true;
      } else if (!line.startsWith('#')) {
        segments.add(base.resolve(line));
        seconds.add(pending);
      }
    }
    return _Playlist(sequence, segments, seconds, ended);
  }
}
