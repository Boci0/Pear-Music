import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'backup_audio_engine.dart';
import 'debug_log.dart';

/// Why a lookup gave no audio. [systemic] failures (a bot check, a rate limit,
/// a server error) mean YouTube is turning this connection away, as opposed to
/// a video that simply is not offered to this client.
class InnerTubeFailure implements Exception {
  InnerTubeFailure(this.message, {this.systemic = false});
  final String message;
  final bool systemic;

  @override
  String toString() => message;
}

/// A direct, picture-only stream link and the height it plays at.
class InnerTubeVideoLink {
  const InnerTubeVideoLink({required this.url, required this.height});
  final String url;
  final int height;
}

/// The fast way to a song's audio: one POST to YouTube's player endpoint as
/// the visionOS client, which hands back plain audio links that need no player
/// code, no JavaScript runtime and no PO token. That is what makes it quick
/// (about 0.3 s to a link, against seconds for yt-dlp, which starts Python and
/// on a phone solves JavaScript challenges) and it never asks for the
/// throttled web formats that return HTTP 403.
///
/// It is tried first and anything it cannot do (an embed-only video, a bot
/// check, YouTube changing the client) falls through to yt-dlp and then the
/// backup engine. The download itself is [BackupAudioEngine.fetch] with this
/// engine's lookup and byte source plugged in.
class InnerTubeAudioEngine {
  InnerTubeAudioEngine._();

  // shortcut: client values are pinned in code, update them here (or ship them
  // in the signed manifest) when YouTube retires this client version.
  static const _clientName = 'VISIONOS';
  static const _clientNumber = '101';
  static const _clientVersion = '1.02';
  static const _userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/26.0 Safari/605.1.15';

  /// Media is read in ranges of this size, as yt-dlp does: YouTube throttles
  /// long unchunked reads.
  static const _chunkBytes = 5 * 1024 * 1024;

  static final Uri _playerUri = Uri.parse(
    'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
  );

  static http.Client? _client;
  static http.Client get _http =>
      debugHttpClient ?? (_client ??= BackupAudioEngine.ipv4Client());

  /// Test seam: replaces the HTTP client.
  @visibleForTesting
  static http.Client? debugHttpClient;

  /// Backs the engine off when YouTube is turning this connection away (a bot
  /// check, a rate limit, a server error), so a bad spell is not made worse by
  /// more lookups; yt-dlp takes over meanwhile. A video that is merely not
  /// offered to this client is not a failure of the engine and is not counted.
  static BackupEngineGuard _guard = BackupEngineGuard(
    videoCooldown: const Duration(seconds: 30),
    pauseAfterFailures: const Duration(minutes: 10),
  );

  static InnerTubeFailure _systemic(String videoId, String message) {
    _guard.recordFailure(videoId, DateTime.now());
    return InnerTubeFailure(message, systemic: true);
  }

  /// Handed to YouTube so a lookup is not treated as a brand new visitor. The
  /// first lookup of a run gets a bot check that carries one; the same lookup
  /// with it goes through.
  static String? _visitorData;

  /// Test seam: replaces the HTTP call. Receives the video id and the visitor
  /// id, returns the decoded response, or throws [InnerTubeFailure].
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(
    String videoId,
    String? visitorData,
  )? debugPlayerOverride;

  @visibleForTesting
  static Stream<List<int>> Function(String url, int bytes)? debugOpenOverride;

  @visibleForTesting
  static void debugReset() {
    _visitorData = null;
    debugHttpClient = null;
    _guard = BackupEngineGuard(
      videoCooldown: const Duration(seconds: 30),
      pauseAfterFailures: const Duration(minutes: 10),
    );
    debugPlayerOverride = null;
    debugOpenOverride = null;
  }

  static Map<String, Object?> _body(String videoId) => {
        'context': {
          'client': {
            'clientName': _clientName,
            'clientVersion': _clientVersion,
            'deviceMake': 'Apple',
            'deviceModel': 'RealityDevice17,1',
            'userAgent': _userAgent,
            'osName': 'visionOS',
            'osVersion': '26.5.23O471',
            'hl': 'en',
            'timeZone': 'UTC',
            'utcOffsetMinutes': 0,
          },
        },
        'videoId': videoId,
        'playbackContext': {
          'contentPlaybackContext': {'html5Preference': 'HTML5_PREF_WANTS'},
        },
        'contentCheckOk': true,
        'racyCheckOk': true,
      };

  static Future<Map<String, dynamic>> _post(
    String videoId,
    String? visitorData,
  ) async {
    final override = debugPlayerOverride;
    if (override != null) return override(videoId, visitorData);
    final req = http.Request('POST', _playerUri)
      ..headers.addAll({
        'User-Agent': _userAgent,
        'Content-Type': 'application/json',
        'X-Youtube-Client-Name': _clientNumber,
        'X-Youtube-Client-Version': _clientVersion,
        'Origin': 'https://www.youtube.com',
        'X-Goog-Visitor-Id': ?visitorData,
      })
      ..body = jsonEncode(_body(videoId));
    final res = await http.Response.fromStream(
      await _http.send(req).timeout(const Duration(seconds: 15)),
    );
    if (res.statusCode != 200) {
      throw InnerTubeFailure('player HTTP ${res.statusCode}', systemic: true);
    }
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  /// The error a fetch reports for a video that is live right now.
  static const String liveStreamError = 'live stream';

  static String? _status(Map<String, dynamic> j) =>
      (j['playabilityStatus'] as Map?)?['status'] as String?;

  /// The player response for [videoId] once YouTube has agreed to play it:
  /// the bot-check retry, the not-offered and live checks. Shared by the audio
  /// and video lookups. Throws [InnerTubeFailure].
  static Future<Map<String, dynamic>> _playable(String videoId) async {
    var sentWith = _visitorData;
    Map<String, dynamic> json;
    try {
      json = await _post(videoId, sentWith);
    } on InnerTubeFailure {
      // One quick retry: a lone 503 under load is normal, a second is not.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      try {
        json = await _post(videoId, sentWith);
      } on InnerTubeFailure catch (e) {
        throw _systemic(videoId, e.message);
      }
    }
    _visitorData ??=
        (json['responseContext'] as Map?)?['visitorData'] as String?;
    var status = _status(json);
    if (status == 'LOGIN_REQUIRED') {
      if (sentWith == null && _visitorData != null) {
        // The expected first answer: retry with the visitor id it returned.
        sentWith = _visitorData;
        json = await _post(videoId, sentWith);
        status = _status(json);
      }
      if (status == 'LOGIN_REQUIRED') {
        // A bot check even with a visitor id: that id is stale or burned.
        _visitorData = null;
        throw _systemic(videoId, 'bot check');
      }
    }
    if (status != 'OK') {
      final reason = (json['playabilityStatus'] as Map?)?['reason'];
      throw InnerTubeFailure('not offered to this client ($status $reason)');
    }
    // A live stream never ends, so it has no file to fetch; playback plays
    // its HLS link instead (see StreamCacheManager.resolveLiveLink).
    if ((json['videoDetails'] as Map?)?['isLive'] == true) {
      throw InnerTubeFailure(liveStreamError);
    }
    return json;
  }

  /// The audio streams [videoId] offers, as candidates for
  /// [BackupAudioEngine.pickStream]. Throws [InnerTubeFailure].
  static Future<List<BackupAudioCandidate>> lookup(String videoId) async {
    final json = await _playable(videoId);
    final formats =
        ((json['streamingData'] as Map?)?['adaptiveFormats'] as List?) ??
            const [];
    final out = <BackupAudioCandidate>[];
    for (final f in formats.cast<Map>()) {
      final mime = f['mimeType'] as String? ?? '';
      final url = f['url'] as String?;
      if (!mime.startsWith('audio/') || url == null) continue;
      final codecs = RegExp(r'codecs="([^"]+)"').firstMatch(mime)?.group(1);
      // The average, not the peak: it matches what yt-dlp's cap compares.
      final bps = (f['averageBitrate'] ?? f['bitrate']) as num? ?? 0;
      out.add(
        BackupAudioCandidate(
          container: mime.contains('mp4') ? 'mp4' : 'webm',
          codec: codecs ?? '',
          kbps: bps / 1000,
          bytes: int.tryParse('${f['contentLength'] ?? 0}') ?? 0,
          handle: url,
        ),
      );
    }
    if (out.isEmpty) throw InnerTubeFailure('no audio links offered');
    return out;
  }

  /// A picture-only link for [videoId], at most [maxHeight] lines tall, for
  /// the video player to read directly. Nothing is downloaded or cached: this
  /// is the same single lookup as the audio's, and the player streams from the
  /// link while the video is on. Throws [InnerTubeFailure].
  static Future<InnerTubeVideoLink> videoLink(
    String videoId, {
    int maxHeight = 480,
  }) async {
    if (!_guard.allow(videoId, DateTime.now())) {
      throw InnerTubeFailure('resting after a block');
    }
    final json = await _playable(videoId);
    final formats =
        ((json['streamingData'] as Map?)?['adaptiveFormats'] as List?) ??
            const [];
    InnerTubeVideoLink? best;
    var bestIsMp4 = false;
    for (final f in formats.cast<Map>()) {
      final mime = f['mimeType'] as String? ?? '';
      final url = f['url'] as String?;
      final height = (f['height'] as num?)?.toInt() ?? 0;
      if (!mime.startsWith('video/') || url == null) continue;
      if (height <= 0 || height > maxHeight) continue;
      // MP4 (H.264) over WebM at the same height: the graphics card decodes
      // it, where VP9 would fall to the processor on many machines.
      final isMp4 = mime.contains('mp4');
      final better = best == null ||
          height > best.height ||
          (height == best.height && isMp4 && !bestIsMp4);
      if (better) {
        best = InnerTubeVideoLink(url: url, height: height);
        bestIsMp4 = isMp4;
      }
    }
    if (best == null) throw InnerTubeFailure('no video links offered');
    _guard.recordSuccess(videoId);
    return best;
  }

  /// The request headers the video link expects, as the lookup was made.
  static const Map<String, String> videoHeaders = {
    'User-Agent': _userAgent,
    'Origin': 'https://www.youtube.com',
  };

  /// Reads a stream's bytes in ranges, as one continuous stream.
  static Stream<List<int>> open(BackupAudioCandidate c, String videoId) async* {
    final url = c.handle! as String;
    final override = debugOpenOverride;
    if (override != null) {
      yield* override(url, c.bytes);
      return;
    }
    final total = c.bytes;
    var pos = 0;
    do {
      final end = total > 0 ? (pos + _chunkBytes).clamp(0, total) - 1 : null;
      final req = http.Request('GET', Uri.parse(url))
        ..headers.addAll({
          'User-Agent': _userAgent,
          'Origin': 'https://www.youtube.com',
          'Range': 'bytes=$pos-${end ?? ''}',
        });
      final res = await _http.send(req);
      if (res.statusCode != 200 && res.statusCode != 206) {
        await res.stream.drain<void>();
        throw res.statusCode == 403 || res.statusCode == 429
            ? _systemic(videoId, 'media HTTP ${res.statusCode}')
            : InnerTubeFailure('media HTTP ${res.statusCode}');
      }
      // A server that ignores Range answers 200 with the whole file; taken as
      // a later chunk it would be appended to what is already written.
      if (res.statusCode == 200 && pos > 0) {
        await res.stream.drain<void>();
        throw InnerTubeFailure('range ignored');
      }
      final before = pos;
      await for (final b in res.stream) {
        pos += b.length;
        yield b;
      }
      if (end == null) break;
      // An empty answer would otherwise be asked for again without end.
      if (pos == before) throw InnerTubeFailure('empty range at byte $pos');
    } while (pos < total);
  }

  /// Fetches [videoId] into [dir] with this engine. Never throws.
  static Future<BackupFetchResult> fetch(
    String videoId, {
    required Directory dir,
    required bool preferAac,
    required bool Function() shouldAbort,
    void Function(File temp, BackupAudioCandidate pick)? onReadable,
  }) async {
    if (!_guard.allow(videoId, DateTime.now())) {
      return const BackupFetchResult.failed('resting after a block');
    }
    try {
      final result = await BackupAudioEngine.fetch(
        videoId,
        dir: dir,
        preferAac: preferAac,
        shouldAbort: shouldAbort,
        load: lookup,
        open: (c) => open(c, videoId),
        label: 'fast-engine',
        lookupTimeout: const Duration(seconds: 15),
        onReadable: onReadable,
      );
      if (result.file != null) _guard.recordSuccess(videoId);
      return result;
    } catch (e) {
      DebugLog.write('[fast-engine] $videoId failed: $e');
      return BackupFetchResult.failed(e.toString().split('\n').first);
    }
  }
}
