import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'debug_log.dart';

/// One audio-only stream a video offers, reduced to what choosing one needs.
class BackupAudioCandidate {
  const BackupAudioCandidate({
    required this.container,
    required this.codec,
    required this.kbps,
    required this.bytes,
    this.handle,
  });

  /// `webm` or `mp4`.
  final String container;

  /// `opus`, `mp4a.40.2`, and so on.
  final String codec;
  final double kbps;
  final int bytes;

  /// The engine's own stream object, handed back when the stream is opened.
  final Object? handle;

  bool get isOpus => codec.toLowerCase().contains('opus');
  bool get isAac => codec.toLowerCase().contains('mp4a');
}

/// What a backup fetch ended with.
class BackupFetchResult {
  const BackupFetchResult.ok(File this.file) : error = null;
  const BackupFetchResult.failed(String this.error) : file = null;

  final File? file;
  final String? error;
}

/// A second, independent way to get a song's audio, used only when yt-dlp could
/// not (missing, out of date, blocked). It runs `youtube_explode_dart`, which
/// shares no code, hosting or update path with yt-dlp, so a takedown or a break
/// on one side leaves the other working.
///
/// It is deliberately plain: it downloads the audio to the cache and returns
/// the file. It does not hand out a direct link for early playback, because
/// the links it resolves belong to a specific client and may not play outside
/// it.
class BackupAudioEngine {
  BackupAudioEngine._();

  /// Chooses the stream to download, mirroring yt-dlp's preference: on desktop
  /// the best Opus at or under [capKbps], then any Opus, then AAC up to the
  /// cap, then the best of whatever is left; with [preferAac] (the phone, where
  /// AAC plays on the hardware decoder) AAC under the cap comes first.
  ///
  /// The cap is 140 here against yt-dlp's 130: this engine reports a stream's
  /// declared bitrate (about 133 kbps for the usual Opus stream) where yt-dlp
  /// reports the average (about 126).
  @visibleForTesting
  static BackupAudioCandidate? pickStream(
    List<BackupAudioCandidate> candidates, {
    required bool preferAac,
    double capKbps = 140,
  }) {
    if (candidates.isEmpty) return null;
    BackupAudioCandidate? best(Iterable<BackupAudioCandidate> list) {
      BackupAudioCandidate? top;
      for (final c in list) {
        if (top == null || c.kbps > top.kbps) top = c;
      }
      return top;
    }

    final opusLow = candidates.where((c) => c.isOpus && c.kbps <= capKbps);
    final opus = candidates.where((c) => c.isOpus);
    final aacLow = candidates.where((c) => c.isAac && c.kbps <= capKbps);
    final order = preferAac
        ? [aacLow, opusLow, opus]
        : [opusLow, opus, aacLow];
    for (final group in order) {
      final pick = best(group);
      if (pick != null) return pick;
    }
    return best(candidates);
  }

  /// File extension the cache looks for, given a stream's container.
  @visibleForTesting
  static String extensionFor(String container) =>
      container.toLowerCase() == 'mp4' ? 'm4a' : container.toLowerCase();

  /// Test seams: replace the stream lookup and the byte source.
  @visibleForTesting
  static Future<List<BackupAudioCandidate>> Function(String videoId)?
      debugLoadOverride;
  @visibleForTesting
  static Stream<List<int>> Function(BackupAudioCandidate stream)?
      debugOpenOverride;

  static YoutubeExplode? _yt;
  static YoutubeExplode get _client => _yt ??= YoutubeExplode(
        httpClient: YoutubeHttpClient(_ipv4Client()),
      );

  /// An HTTP client that connects over IPv4 first. On a network with a broken
  /// IPv6 route the stock client stalls on the first address it tries, which
  /// is exactly when a backup is needed; yt-dlp is run with `--force-ipv4` for
  /// the same reason.
  static http.Client _ipv4Client() {
    final inner = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..connectionFactory = (uri, proxyHost, proxyPort) async {
        final host = proxyHost ?? uri.host;
        final port = proxyPort ?? uri.port;
        // The factory hands back a finished connection, so an https request
        // needs the TLS handshake done here, against the real host name.
        final secure = proxyHost == null && uri.scheme == 'https';
        Future<ConnectionTask<Socket>> connect(Object address) => secure
            ? SecureSocket.startConnect(address, port, supportedProtocols: null)
            : Socket.startConnect(address, port);
        try {
          final v4 = await InternetAddress.lookup(
            host,
            type: InternetAddressType.IPv4,
          );
          if (v4.isNotEmpty) return await connect(v4.first);
        } catch (_) {}
        return connect(host);
      };
    return IOClient(inner);
  }

  static Future<List<BackupAudioCandidate>> _load(String videoId) async {
    final override = debugLoadOverride;
    if (override != null) return override(videoId);
    final manifest = await _client.videos.streamsClient.getManifest(videoId);
    return [
      for (final s in manifest.audioOnly)
        BackupAudioCandidate(
          container: s.container.name,
          codec: s.audioCodec,
          kbps: s.bitrate.kiloBitsPerSecond,
          bytes: s.size.totalBytes,
          handle: s,
        ),
    ];
  }

  static Stream<List<int>> _open(BackupAudioCandidate c) {
    final override = debugOpenOverride;
    if (override != null) return override(c);
    return _client.videos.streamsClient.get(c.handle! as AudioOnlyStreamInfo);
  }

  /// Copies [source] into [sink] and returns the byte count, or an error.
  ///
  /// Written with a manual listener on purpose. An `await for` over a stream
  /// that has timed out waits for the stream to finish cancelling before it
  /// reports the timeout, and a stalled network stream can sit in that cancel
  /// forever, so the timeout would never reach the caller. Here the timers
  /// complete the result themselves and the cancel is left to finish (or not)
  /// in the background.
  static Future<({int bytes, String? error})> _copy(
    Stream<List<int>> source,
    IOSink sink, {
    required bool Function() shouldAbort,
    required Duration idleTimeout,
    required Duration totalTimeout,
  }) async {
    final done = Completer<String?>();
    var bytes = 0;
    Timer? idle;
    final deadline = DateTime.now().add(totalTimeout);

    void finish(String? error) {
      if (done.isCompleted) return;
      idle?.cancel();
      done.complete(error);
    }

    void arm() {
      idle?.cancel();
      idle = Timer(
        idleTimeout,
        () => finish('stalled for ${idleTimeout.inSeconds}s'),
      );
    }

    final sub = source.listen(
      (chunk) {
        if (done.isCompleted) return;
        if (shouldAbort()) return finish('cancelled');
        if (DateTime.now().isAfter(deadline)) return finish('took too long');
        sink.add(chunk);
        bytes += chunk.length;
        arm();
      },
      onError: (Object e) => finish(e.toString().split('\n').first),
      onDone: () => finish(null),
      cancelOnError: true,
    );
    arm();
    final error = await done.future;
    unawaited(sub.cancel().then<void>((_) {}, onError: (_) {}));
    return (bytes: bytes, error: error);
  }

  /// Downloads the best audio for [videoId] into [dir] as `<id>.<ext>` and
  /// returns it. The bytes go to a temporary name first, so a half-written file
  /// is never mistaken for a cached song. [shouldAbort] is polled between
  /// chunks so a cancelled play stops the transfer.
  static Future<BackupFetchResult> fetch(
    String videoId, {
    required Directory dir,
    required bool preferAac,
    required bool Function() shouldAbort,
    Duration lookupTimeout = const Duration(seconds: 25),
    Duration idleTimeout = const Duration(seconds: 20),
    Duration totalTimeout = const Duration(seconds: 150),
  }) async {
    File? temp;
    try {
      final candidates = await _load(videoId).timeout(lookupTimeout);
      final pick = pickStream(candidates, preferAac: preferAac);
      if (pick == null) {
        return const BackupFetchResult.failed('no audio streams offered');
      }
      final ext = extensionFor(pick.container);
      // `.tmp.` in the name is what the cache's start-up sweep treats as scrap.
      temp = File(p.join(dir.path, '$videoId.tmp.$ext'));
      final finalFile = File(p.join(dir.path, '$videoId.$ext'));
      if (await temp.exists()) await temp.delete();

      final sink = temp.openWrite();
      final copied = await _copy(
        _open(pick),
        sink,
        shouldAbort: shouldAbort,
        idleTimeout: idleTimeout,
        totalTimeout: totalTimeout,
      );
      await sink.close();
      if (copied.error != null) return BackupFetchResult.failed(copied.error!);
      final written = copied.bytes;

      // A cut-off transfer must not become a cache hit: demand nearly the full
      // size when the engine reported one.
      final tooShort = written < 50000 ||
          (pick.bytes > 0 && written < pick.bytes * 0.98);
      if (tooShort) {
        return BackupFetchResult.failed(
          'incomplete download ($written of ${pick.bytes} bytes)',
        );
      }
      if (await finalFile.exists()) await finalFile.delete();
      await temp.rename(finalFile.path);
      temp = null;
      DebugLog.write(
        '[backup-engine] $videoId ${pick.container}/${pick.codec} '
        '${pick.kbps.round()}k, ${(written / 1024).round()} KB',
      );
      return BackupFetchResult.ok(finalFile);
    } catch (e) {
      return BackupFetchResult.failed(e.toString().split('\n').first);
    } finally {
      if (temp != null) {
        try {
          if (await temp.exists()) await temp.delete();
        } catch (_) {}
      }
    }
  }
}
