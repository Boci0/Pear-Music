import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import 'debug_log.dart';
import 'library_service.dart';
import 'youtube_service.dart';
import 'ytdlp_prewarmer.dart';

/// Why a stream fetch failed. Drives the playback error handling: only
/// [unavailable] tracks are skipped automatically; everything else stays on
/// the failed track with an explanation and a retry.
enum StreamFetchFailureKind {
  /// YouTube refused the request (HTTP 403 / bot check). Usually temporary.
  blocked,

  /// The video itself cannot be served (deleted, private, members-only).
  unavailable,

  /// Network trouble: timeouts, resets, no connection.
  network,

  /// yt-dlp is missing or broken on this device.
  engine,

  /// Anything not covered above.
  unknown,
}

/// A failed stream fetch with enough context to explain it to the user.
class StreamFetchFailure {
  final String videoId;
  final StreamFetchFailureKind kind;

  /// Raw technical detail (yt-dlp stderr, plugin error), kept for diagnostics.
  final String detail;

  const StreamFetchFailure({
    required this.videoId,
    required this.kind,
    required this.detail,
  });
}

/// High-speed ephemeral radio cache manager.
/// Streams audio directly into local disk files using optimized audio-only extractors.
/// A direct audio link yt-dlp resolved for a video, printed by the fetch
/// process just before it starts downloading. Playback streams from it right
/// away instead of waiting for the whole file to reach the cache.
class ResolvedStream {
  final String url;

  /// Request headers yt-dlp would use for this link (user agent and so on).
  final Map<String, String> headers;

  /// Container extension of the chosen format (webm, m4a).
  final String? ext;

  /// Exact size of the audio file in bytes, when YouTube reports it.
  final int? filesize;

  /// The cache file the fetch is writing, when playback should read that
  /// instead of requesting [url] itself (Android: YouTube blocks the phone's
  /// player from fetching the link directly, but not yt-dlp).
  final String? localPath;

  const ResolvedStream({
    required this.url,
    this.headers = const {},
    this.ext,
    this.filesize,
    this.localPath,
  });

  ResolvedStream withLocalPath(String path) => ResolvedStream(
    url: url,
    headers: headers,
    ext: ext,
    filesize: filesize,
    localPath: path,
  );
}

class StreamCacheManager {
  static const int maxCacheBytes = 500 * 1024 * 1024; // 500 MB cap
  static const int targetEvictionBytes = 400 * 1024 * 1024; // prune to 400 MB
  static const int maxTrackCount = 100;

  /// High-efficiency Opus-optimized audio format selector for desktop (~96-128 kbps Opus).
  /// Prioritizes Opus streams within 96-130 kbps, falling back to any Opus,
  /// then standard best audio.
  static const String desktopAudioFormatArg =
      'ba[acodec=opus][abr<=130]/ba[acodec=opus]/ba[ext=opus]/ba[abr<=128]/ba/bestaudio/b/best';

  /// Hardware-accelerated DSP audio format selector for Android (Format 140, AAC-LC 128 kbps .m4a).
  /// Enables native zero-CPU DSP offloading and minimizes background battery drain.
  static const String androidAudioFormatArg =
      '140/bestaudio[ext=m4a]/bestaudio[abr<=128]/bestaudio/ba';

  /// Platform-adaptive audio format selector:
  /// Uses hardware-accelerated AAC on Android, and high-efficiency Opus on desktop.
  static String get audioFormatArg => getAudioFormatArg();

  static String getAudioFormatArg() {
    if (!kIsWeb && Platform.isAndroid) {
      return androidAudioFormatArg;
    }
    return desktopAudioFormatArg;
  }

  static Set<String> _activeQueueVideoIds = {};
  /// Protects all tracks currently in the active queue from being evicted.
  static void setActiveQueueVideoIds(Iterable<String> ids) {
    _activeQueueVideoIds = ids.toSet();
  }

  /// Why a stream fetch failed. Playback uses this to decide between stopping
  /// on the track with a retry and skipping a track that can never play.
  /// YouTube's HTTP 403 / bot-check answers are usually temporary, so they
  /// must never be treated as "this song is gone".
  static final Map<String, StreamFetchFailure> _lastFetchFailures = {};

  /// Test seam: when set, replaces the real yt-dlp download step. Tests use it
  /// to simulate a failure (recording a failure via [recordFetchFailure]) or
  /// a cache hit without touching the network.
  @visibleForTesting
  static Future<File?> Function(String videoId, {required bool isPreload})?
      debugEnsureStreamCachedOverride;

  /// Maps a raw yt-dlp / plugin error into something playback can act on.
  static StreamFetchFailureKind classifyFetchFailure(String raw) {
    final s = raw.toLowerCase();
    // Check "gone for good" answers first: "Private video. Sign in if you have
    // been granted access" also contains "sign in", which must not win. These
    // are skipped: no amount of retrying makes them playable here.
    if (s.contains('private video') ||
        s.contains('video unavailable') ||
        s.contains('this video is unavailable') ||
        s.contains('no longer available') ||
        s.contains('has been removed') ||
        s.contains('members-only') ||
        s.contains('available to this channel') ||
        s.contains('removed by the uploader') ||
        s.contains('account associated with this video has been terminated') ||
        s.contains('not available in your country') ||
        s.contains('not made this video available') ||
        s.contains('confirm your age') ||
        s.contains('inappropriate for some users')) {
      return StreamFetchFailureKind.unavailable;
    }
    if (s.contains('403') ||
        s.contains('forbidden') ||
        s.contains('sign in to confirm') ||
        s.contains('not a bot') ||
        s.contains('botcheck') ||
        s.contains('bot check')) {
      return StreamFetchFailureKind.blocked;
    }
    if (s.contains('not installed') ||
        s.contains('no such file') ||
        s.contains('cannot find') ||
        s.contains('yt-dlp is missing')) {
      return StreamFetchFailureKind.engine;
    }
    if (s.contains('timed out') ||
        s.contains('timeout') ||
        s.contains('socket') ||
        s.contains('connection') ||
        s.contains('network') ||
        s.contains('unable to download video data') ||
        s.contains('read error') ||
        s.contains('getaddrinfo')) {
      return StreamFetchFailureKind.network;
    }
    return StreamFetchFailureKind.unknown;
  }

  /// Records why the last fetch of [videoId] failed, so the playback layer can
  /// explain it instead of silently moving on.
  static void recordFetchFailure(String videoId, String raw) {
    _lastFetchFailures[videoId] = StreamFetchFailure(
      videoId: videoId,
      kind: classifyFetchFailure(raw),
      detail: raw.trim(),
    );
    // The map only exists to carry one explanation to the caller; keep it tiny
    // so a long session of preload failures cannot grow it without bound.
    while (_lastFetchFailures.length > 40) {
      _lastFetchFailures.remove(_lastFetchFailures.keys.first);
    }
  }

  /// Removes and returns the failure recorded for [videoId], if any.
  static StreamFetchFailure? takeFetchFailure(String videoId) {
    return _lastFetchFailures.remove(videoId);
  }

  /// Drops yt-dlp's persistent player/session cache. A stale cached player is
  /// a common cause of HTTP 403 responses, so an explicit retry rebuilds it.
  static Future<void> refreshYtDlpCache() async {
    try {
      final dir = await getYtDlpCacheDirectory();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _ytdlpCacheDir = null;
      DebugLog.write('[cache] yt-dlp player cache refreshed for a clean retry');
    } catch (e) {
      DebugLog.write('[cache] could not refresh yt-dlp cache: $e');
    }
  }

  static Directory? _cacheDir;

  /// Gets or creates the radio stream cache directory in temporary storage.
  static Future<Directory> getCacheDirectory() async {
    if (_cacheDir != null && await _cacheDir!.exists()) {
      return _cacheDir!;
    }
    final temp = await getTemporaryDirectory();
    final dir = Directory(p.join(temp.path, 'peerm_radio_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  static Directory? _ytdlpCacheDir;

  /// Dedicated persistent cache directory for yt-dlp to preserve player JS functions and session tokens.
  static Future<Directory> getYtDlpCacheDirectory() async {
    if (_ytdlpCacheDir != null && await _ytdlpCacheDir!.exists()) {
      return _ytdlpCacheDir!;
    }
    final baseDir = await getCacheDirectory();
    final ytdlpCache = Directory(p.join(baseDir.path, '.ytdlp_cache'));
    if (!await ytdlpCache.exists()) {
      await ytdlpCache.create(recursive: true);
    }
    _ytdlpCacheDir = ytdlpCache;
    return ytdlpCache;
  }

  static final Map<String, Completer<File?>> _inFlightDownloads = {};
  static final Set<String> _cachedVideoIds = {};
  static int _slidingWindowSequence = 0;
  static int _downloadInvocationToken = 0;
  static int _cachedTotalBytes = 0;

  /// Live notifier broadcasting current cache bytes for immediate reactive UI binding.
  static final ValueNotifier<int> cacheBytesNotifier = ValueNotifier<int>(0);

  static void _setCachedTotalBytes(int bytes) {
    _cachedTotalBytes = bytes;
    cacheBytesNotifier.value = bytes;
  }

  /// Returns live O(1) stats of cache size, track count, and active downloads.
  static ({int trackCount, int totalBytes, int inFlightCount}) getCacheStats() {
    return (
      trackCount: _cachedVideoIds.length,
      totalBytes: _cachedTotalBytes,
      inFlightCount: _inFlightDownloads.length,
    );
  }

  /// Pre-scans existing cache files on app launch for instantaneous lookup.
  static Future<void> warmUp() async {
    final startBytes = _cachedTotalBytes;
    try {
      final dir = await getCacheDirectory();
      final files = await dir.list().where((e) => e is File).cast<File>().toList();
      int total = 0;
      final now = DateTime.now();
      for (final f in files) {
        final name = p.basename(f.path);
        if (name.contains('.tmp.') || name.contains('.part.') || name.startsWith('tmp_')) {
          try {
            final stat = await f.stat();
            if (now.difference(stat.modified) > const Duration(minutes: 2)) {
              await f.delete();
            }
          } catch (_) {}
          continue;
        }
        final len = await f.length();
        if (len > 50000) {
          final rawName = p.basenameWithoutExtension(name);
          final id = rawName.contains('.') ? rawName.split('.').first : rawName;
          _cachedVideoIds.add(id);
          total += len;
        }
      }
      final concurrentDelta = _cachedTotalBytes - startBytes;
      _setCachedTotalBytes(total + (concurrentDelta > 0 ? concurrentDelta : 0));
      DebugLog.write('[cache] Warmed up ${_cachedVideoIds.length} tracks from disk cache');
      unawaited(enforceCacheQuota());
    } catch (e) {
      debugPrint('[StreamCacheManager] warmUp error: $e');
    }
  }

  /// Synchronous memory check whether a track is fully cached on disk.
  static bool isStreamCachedSync(String videoId) {
    return _cachedVideoIds.contains(videoId);
  }

  /// Returns the in-flight download future if this track is currently being cached.
  static Future<File?>? getInFlightDownload(String videoId) {
    return _inFlightDownloads[videoId]?.future;
  }

  /// Quick cache check: returns the cached file if it exists.
  static Future<File?> getCachedFile(String videoId) async {
    final dir = await getCacheDirectory();

    // 1. Direct cache files: $videoId.$ext
    for (final ext in ['m4a', 'opus', 'webm', 'mp4', 'ogg', 'mp3']) {
      final f = File(p.join(dir.path, '$videoId.$ext'));
      if (await f.exists() && (await f.length()) > 50000) {
        _cachedVideoIds.add(videoId);
        return f;
      }
    }
    final bare = File(p.join(dir.path, videoId));
    if (await bare.exists() && (await bare.length()) > 50000) {
      _cachedVideoIds.add(videoId);
      return bare;
    }

    // 2. Backward compatibility with legacy tagged files: $videoId.*.$ext
    for (final tag in ['standard', 'high', 'dataSaver']) {
      for (final ext in ['opus', 'm4a', 'webm', 'mp4', 'ogg', 'mp3']) {
        final f = File(p.join(dir.path, '$videoId.$tag.$ext'));
        if (await f.exists() && (await f.length()) > 50000) {
          _cachedVideoIds.add(videoId);
          return f;
        }
      }
    }

    return null;
  }

  /// Inspects any cached file details on disk for a given [videoId].
  static Future<({bool isCached, String? filePath, int? fileSize, String? ext})> inspectTrackCache(String videoId) async {
    try {
      final file = await getCachedFile(videoId);
      if (file != null && await file.exists()) {
        final len = await file.length();
        final ext = p.extension(file.path).replaceFirst('.', '');
        return (
          isCached: true,
          filePath: file.path,
          fileSize: len,
          ext: ext,
        );
      }
    } catch (_) {}
    return (
      isCached: false,
      filePath: null,
      fileSize: null,
      ext: null,
    );
  }

  /// Prefix of the line the desktop fetch prints once the format is chosen
  /// (see [_desktopStreamArgs]), so it can be told apart from anything else
  /// yt-dlp writes to stdout.
  static const String streamLinePrefix = 'PEARSTREAM ';

  /// Parses a stream line printed by yt-dlp into a [ResolvedStream], or null
  /// when [line] is not one (or is malformed).
  @visibleForTesting
  static ResolvedStream? parseStreamLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith(streamLinePrefix)) return null;
    try {
      final data = jsonDecode(trimmed.substring(streamLinePrefix.length));
      if (data is! Map) return null;
      final url = data['url'];
      if (url is! String || !url.startsWith('http')) return null;
      final rawHeaders = data['http_headers'];
      final headers = <String, String>{};
      if (rawHeaders is Map) {
        rawHeaders.forEach((key, value) {
          if (key is String && value is String) headers[key] = value;
        });
      }
      final ext = data['ext'];
      final filesize = data['filesize'];
      return ResolvedStream(
        url: url,
        headers: headers,
        ext: ext is String ? ext : null,
        filesize: filesize is int && filesize > 0 ? filesize : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Links printed by fetches that are still running, keyed by video id, so a
  /// caller that joins an in-flight fetch late still gets the link.
  static final Map<String, ResolvedStream> _resolvedStreams = {};

  /// Callers waiting for a video's link (see [ensureStreamCached]'s
  /// `onStreamUrl`).
  static final Map<String, List<void Function(ResolvedStream)>>
      _streamListeners = {};

  /// Test seam: acts as if the running fetch for [videoId] printed [stream].
  @visibleForTesting
  static void debugPublishResolvedStream(
    String videoId,
    ResolvedStream stream,
  ) => _publishResolvedStream(videoId, stream);

  static void _publishResolvedStream(String videoId, ResolvedStream stream) {
    _resolvedStreams[videoId] = stream;
    final listeners = _streamListeners[videoId];
    if (listeners == null) return;
    for (final listener in List.of(listeners)) {
      listener(stream);
    }
  }

  /// Video id of each running Android fetch, keyed by its process id, so a
  /// link the plugin reports can be matched to its video.
  static final Map<String, String> _androidFetchVideoIds = {};

  /// Output file of each running Android fetch, keyed by its process id.
  static final Map<String, String> _androidFetchPaths = {};
  static bool _androidLinkHandlerInstalled = false;

  /// Listens for the Android plugin's `streamResolved` calls: the embedded
  /// yt-dlp prints the same stream line as the desktop fetch, and the plugin
  /// forwards it (with the process id) as soon as it appears.
  static void _installAndroidLinkHandler() {
    if (_androidLinkHandlerInstalled) return;
    _androidLinkHandlerInstalled = true;
    const MethodChannel(
      'peerm/ytdlp',
    ).setMethodCallHandler(handleAndroidPluginCall);
  }

  /// Handles calls from the Android yt-dlp plugin (see
  /// [_installAndroidLinkHandler]).
  @visibleForTesting
  static Future<Object?> handleAndroidPluginCall(MethodCall call) async {
    if (call.method != 'streamResolved') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final processId = args['processId'];
    final line = args['line'];
    if (processId is! String || line is! String) return null;
    final videoId = _androidFetchVideoIds[processId];
    final parsed = parseStreamLine(line);
    if (videoId != null && parsed != null) {
      // Playback reads the file yt-dlp is writing rather than the link:
      // YouTube turns the phone's player away when it requests it directly.
      final path = _androidFetchPaths[processId];
      final stream = path == null ? parsed : parsed.withLocalPath(path);
      DebugLog.write('[cache] Android stream ready for $videoId (file: $path)');
      _publishResolvedStream(videoId, stream);
    }
    return null;
  }

  /// Test seam: registers a running Android fetch, as the embedded download
  /// path does, so [handleAndroidPluginCall] can match its links.
  @visibleForTesting
  static void debugTrackAndroidFetch(
    String processId,
    String videoId, {
    String? outputPath,
  }) {
    _androidFetchVideoIds[processId] = videoId;
    if (outputPath != null) _androidFetchPaths[processId] = outputPath;
  }

  static String? _activeDownloadingVideoId;
  static bool _isActiveDownloadPreload = false;
  static String? _activeProcessId;
  static Process? _activeDesktopProcess;

  /// Kills the running desktop fetch process, if any. Cancellation frees the
  /// single connection immediately, which is what keeps skips and foreground
  /// plays snappy; the pre-booted spare is idle and is left alone.
  static void _killActiveDesktopEngine() {
    final process = _activeDesktopProcess;
    if (process != null) {
      _activeDesktopProcess = null;
      try {
        YoutubeService.killProcessTree(process.pid);
      } catch (_) {}
    }
  }

  /// Options for a desktop stream fetch. The URL and the `-o` template are
  /// added per invocation (see [YtDlpPrewarmer.buildStdinArgs]).
  ///
  /// The `--print` line hands playback the chosen format's direct link (plus
  /// the headers to fetch it with) as soon as the format is picked, before
  /// the download starts, so a track can play while it is still being
  /// cached. `--print` normally implies a dry run, hence `--no-simulate`.
  /// Every fetch prints it (preloads just ignore it), which keeps the args
  /// identical so the pre-booted spare process always matches. The Android
  /// plugin adds the same line to its downloads (see YtDlpPlugin.kt).
  ///
  /// With [skipPlayerJs] yt-dlp only takes formats that need nothing from
  /// YouTube's player code. Most videos offer one, and it skips downloading
  /// that code and solving its JavaScript challenges (seconds on a desktop,
  /// about 8 s on a phone). A fetch that finds no such format retries without.
  static List<String> _desktopStreamArgs(String ytdlpCachePath, {bool skipPlayerJs = true}) {
    return [
      '--no-simulate',
      '--print',
      'video:$streamLinePrefix%(.{url,http_headers,ext,filesize})j',
      '-f',
      getAudioFormatArg(),
      '--cache-dir',
      ytdlpCachePath,
      '--extractor-args',
      skipPlayerJs
          ? 'youtube:skip=webpage,authcheck,translated_subs,hls;player_skip=js'
          : 'youtube:skip=webpage,authcheck,translated_subs,hls',
      '--no-playlist',
      '--no-part',
      '--no-mtime',
      '--no-warnings',
      '--no-check-certificates',
      '--quiet',
      '--force-ipv4',
      '--concurrent-fragments',
      '2',
      '--http-chunk-size',
      '5M',
      '--buffer-size',
      '64k',
      '--socket-timeout',
      '10',
      '--retries',
      '2',
      '--extractor-retries',
      '1',
    ];
  }

  /// Boots a spare yt-dlp process so the next fetch starts without paying the
  /// ~2 s startup. Called once after launch and again after every fetch, so
  /// the cost lands while the app is idle.
  static Future<void> prewarmDesktopYtDlp() async {
    if (!YtDlpPrewarmer.enabled || kIsWeb || Platform.isAndroid) return;
    try {
      final bin = await YoutubeService.ytDlpPath();
      if (bin == null) return;
      final dir = await getCacheDirectory();
      final ytdlpCache = await getYtDlpCacheDirectory();
      await YtDlpPrewarmer.instance.prewarm(
        bin: bin,
        baseArgs: _desktopStreamArgs(ytdlpCache.path),
        outputTemplate: p.join(dir.path, '%(id)s.%(ext)s'),
      );
    } catch (e) {
      DebugLog.write('[ytdlp-prewarm] skipped: $e');
    }
  }

  /// Whether any audio stream download is currently active.
  static bool get isAnyDownloadActive => _activeDownloadingVideoId != null;

  /// Whether the currently active download is a background preload task.
  static bool get isActiveDownloadPreload => _isActiveDownloadPreload;

  /// Whether a foreground (current song) audio download is currently active.
  static bool get isForegroundDownloadActive =>
      _activeDownloadingVideoId != null && !_isActiveDownloadPreload;

  /// Video ID of the current active audio stream download, if any.
  static String? get activeDownloadingVideoId => _activeDownloadingVideoId;

  /// Cancels any active background preload sequence immediately.
  static void cancelPreload({String? exceptVideoId}) {
    _slidingWindowSequence++;
    if (exceptVideoId != null && _activeDownloadingVideoId == exceptVideoId) {
      DebugLog.write('[preload] Preserving active in-flight download for $exceptVideoId');
      return;
    }
    if (_isActiveDownloadPreload) {
      final activeId = _activeProcessId;
      if (activeId != null && YoutubeService.isEmbeddedYtDlpSupported) {
        _activeProcessId = null;
        try {
          const MethodChannel('peerm/ytdlp').invokeMethod('cancel', {'processId': activeId});
        } catch (_) {}
      }
      _killActiveDesktopEngine();
      final abandoned = _activeDownloadingVideoId;
      if (abandoned != null && _inFlightDownloads.containsKey(abandoned)) {
        if (!_inFlightDownloads[abandoned]!.isCompleted) {
          _inFlightDownloads[abandoned]?.complete(null);
        }
        _inFlightDownloads.remove(abandoned);
      }
      _activeDownloadingVideoId = null;
      _isActiveDownloadPreload = false;
      DebugLog.write('[preload] Preload cancelled, new sequence=$_slidingWindowSequence');
    }
  }

  /// Terminates any ongoing yt-dlp download process (foreground or background preload)
  /// if it does not match [exceptVideoId], releasing native heap, CPU, and network immediately.
  static void cancelActiveDownload({String? exceptVideoId}) {
    _slidingWindowSequence++;
    _downloadInvocationToken++;
    if (exceptVideoId == null || _activeDownloadingVideoId != exceptVideoId) {
      final abandonedId = _activeDownloadingVideoId;
      final activeId = _activeProcessId;
      if (activeId != null && YoutubeService.isEmbeddedYtDlpSupported) {
        _activeProcessId = null;
        try {
          const MethodChannel('peerm/ytdlp').invokeMethod('cancel', {'processId': activeId});
        } catch (_) {}
      }
      _killActiveDesktopEngine();
      if (exceptVideoId == null) {
        for (final entry in _inFlightDownloads.entries) {
          if (!entry.value.isCompleted) {
            entry.value.complete(null);
          }
        }
        _inFlightDownloads.clear();
      } else if (abandonedId != null && _inFlightDownloads.containsKey(abandonedId)) {
        if (!_inFlightDownloads[abandonedId]!.isCompleted) {
          _inFlightDownloads[abandonedId]?.complete(null);
        }
        _inFlightDownloads.remove(abandonedId);
      }
      _activeDownloadingVideoId = null;
      _isActiveDownloadPreload = false;
      if (abandonedId != null) {
        DebugLog.write('[cache] cancelActiveDownload: aborted abandoned download for $abandonedId');
      }
    }
  }

  /// Sequentially pre-downloads a tight 1-track lookahead window
  /// in the background using a single-queue worker to enable instant 0ms playback.
  static void preloadSlidingWindow(
    List<String> videoIds, {
    void Function(String videoId)? onTrackCached,
    void Function()? onDone,
  }) {
    final seq = ++_slidingWindowSequence;
    unawaited(() async {
      try {
        // Sequential single-track lookahead window: loads the next track, and only moves
        // to the following one once the current target is fully cached.
        for (final id in videoIds) {
          if (seq != _slidingWindowSequence) {
            DebugLog.write('[preload] Preload sequence aborted for $id');
            break;
          }
          if (id.isEmpty) continue;
          final diskCached = await getCachedFile(id);
          if (diskCached != null) {
            _cachedVideoIds.add(id);
            onTrackCached?.call(id);
            continue;
          }
          try {
            DebugLog.write('[preload] Buffering upcoming track: $id');
            var file = await ensureStreamCached(id, isPreload: true);
            if (seq != _slidingWindowSequence) break;
            // A 403 or bot check is usually temporary. Retry once with a
            // clean yt-dlp cache, the same as the manual Retry does, so the
            // next track does not start cold (or fail) when it comes up.
            if (file == null && _lastFetchFailures[id]?.kind == StreamFetchFailureKind.blocked) {
              DebugLog.write('[preload] $id was blocked, retrying once with a clean yt-dlp cache');
              await refreshYtDlpCache();
              if (seq != _slidingWindowSequence) break;
              file = await ensureStreamCached(id, isPreload: true);
              if (seq != _slidingWindowSequence) break;
            }
            if (file != null) {
              DebugLog.write('[preload] Buffered upcoming track ready on disk: $id');
              onTrackCached?.call(id);
            }
          } catch (_) {}
        }
      } finally {
        if (seq == _slidingWindowSequence) {
          onDone?.call();
        }
      }
    }());
  }

  /// Removes any partially written cache artifacts for [videoId]. Killed or
  /// failed downloads must never be adopted as cache hits, so this drops
  /// every `$videoId.*` file, including `--no-part` truncated finals.
  static Future<void> _deletePartialArtifacts(String videoId) async {
    try {
      final dir = await getCacheDirectory();
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name == videoId || name.startsWith('$videoId.')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
      _cachedVideoIds.remove(videoId);
    } catch (_) {}
  }

  /// Ensures the audio stream for [videoId] is downloaded into the local cache
  /// using yt-dlp exclusively with client emulation to bypass all rate limits and bot challenges.
  /// Strictly enforces single-concurrency to prevent multiple downloads from splitting bandwidth.
  ///
  /// When [onStreamUrl] is given, it is called with the direct audio link as
  /// soon as the fetch has resolved it (before the download is done), on the
  /// desktop engine and on Android's embedded one, including when this call
  /// joins a fetch that is already running. It is not called on a cache hit.
  static Future<File?> ensureStreamCached(
    String videoId, {
    bool isPreload = false,
    void Function(ResolvedStream stream)? onStreamUrl,
  }) async {
    if (onStreamUrl == null) {
      return _ensureStreamCached(videoId, isPreload: isPreload);
    }
    final listeners = _streamListeners.putIfAbsent(videoId, () => []);
    listeners.add(onStreamUrl);
    final alreadyResolved = _resolvedStreams[videoId];
    if (alreadyResolved != null) onStreamUrl(alreadyResolved);
    try {
      return await _ensureStreamCached(videoId, isPreload: isPreload);
    } finally {
      listeners.remove(onStreamUrl);
      if (listeners.isEmpty && identical(_streamListeners[videoId], listeners)) {
        _streamListeners.remove(videoId);
      }
    }
  }

  static Future<File?> _ensureStreamCached(
    String videoId, {
    bool isPreload = false,
  }) async {
    final token = ++_downloadInvocationToken;
    final preloadSeq = _slidingWindowSequence;
    // A new attempt starts clean: any explanation from an earlier attempt for
    // this video must not be reused for the outcome of this one.
    _lastFetchFailures.remove(videoId);

    final existing = await getCachedFile(videoId);
    if (existing != null) {
      DebugLog.write('[cache] Disk cache HIT for $videoId (0ms)');
      return existing;
    }
    if (token != _downloadInvocationToken) return null;
    if (isPreload && preloadSeq != _slidingWindowSequence) return null;

    final override = debugEnsureStreamCachedOverride;
    if (override != null) {
      final result = await override(videoId, isPreload: isPreload);
      if (result == null) {
        _lastFetchFailures.putIfAbsent(
          videoId,
          () => StreamFetchFailure(
            videoId: videoId,
            kind: StreamFetchFailureKind.unknown,
            detail: 'simulated failure',
          ),
        );
      }
      return result;
    }

    // Single-flight deduplication: join existing download if already in progress for this videoId
    if (_inFlightDownloads.containsKey(videoId)) {
      DebugLog.write('[cache] Joining in-flight download for $videoId');
      return await _inFlightDownloads[videoId]!.future;
    }

    // Single-concurrency coordinator:
    // If a background preload requests a download while another download is running,
    // wait for the active download to finish instead of permanently abandoning preload.
    if (isPreload && _activeDownloadingVideoId != null) {
      final activeId = _activeDownloadingVideoId!;
      if (activeId == videoId) {
        return await _inFlightDownloads[videoId]?.future;
      }
      DebugLog.write('[cache] Preload for $videoId waiting for active download $activeId to complete...');
      final activeFuture = _inFlightDownloads[activeId]?.future;
      if (activeFuture != null) {
        try {
          await activeFuture.timeout(const Duration(seconds: 45));
        } catch (_) {}
      } else {
        int waitAttempts = 0;
        while (_activeDownloadingVideoId != null && waitAttempts < 40) {
          await Future.delayed(const Duration(milliseconds: 150));
          waitAttempts++;
        }
      }
      final cachedAfterWait = await getCachedFile(videoId);
      if (cachedAfterWait != null) {
        return cachedAfterWait;
      }
      if (token != _downloadInvocationToken || (isPreload && preloadSeq != _slidingWindowSequence) || _activeDownloadingVideoId != null) {
        DebugLog.write('[cache] Another download took concurrency lock after wait or sequence cancelled, deferring $videoId');
        return null;
      }
    }
    if (token != _downloadInvocationToken) return null;
    if (isPreload && preloadSeq != _slidingWindowSequence) return null;

    // If direct playback is requested while another download is running, abort the active download to
    // dedicate 100% bandwidth to the track the user is actively waiting to hear.
    if (!isPreload && _activeDownloadingVideoId != null && _activeDownloadingVideoId != videoId) {
      DebugLog.write('[cache] Direct play for $videoId preempting active download $_activeDownloadingVideoId');
      if (_activeProcessId != null && YoutubeService.isEmbeddedYtDlpSupported) {
        try {
          const MethodChannel('peerm/ytdlp').invokeMethod('cancel', {'processId': _activeProcessId});
        } catch (_) {}
        _activeProcessId = null;
      }
      _killActiveDesktopEngine();
      _activeDownloadingVideoId = null;
      _isActiveDownloadPreload = false;
    }

    _activeDownloadingVideoId = videoId;
    _isActiveDownloadPreload = isPreload;

    final completer = Completer<File?>();
    _inFlightDownloads[videoId] = completer;
    final stopwatch = Stopwatch()..start();

    var failureRecorded = false;
    void recordFailure(String raw) {
      recordFetchFailure(videoId, raw);
      failureRecorded = true;
    }

    try {
      final dir = await getCacheDirectory();

      // Android embedded yt-dlp
      if (YoutubeService.isEmbeddedYtDlpSupported) {
        final tempPart = File(p.join(dir.path, '$videoId.m4a'));
        final processId = 'peerm-fast-$videoId-${DateTime.now().millisecondsSinceEpoch}';
        _activeProcessId = processId;
        _installAndroidLinkHandler();
        _androidFetchVideoIds[processId] = videoId;
        _androidFetchPaths[processId] = tempPart.path;
        try {
          DebugLog.write('[cache] Android embedded yt-dlp downloading $videoId');
          // Same persistent yt-dlp cache as desktop: without it every fetch
          // re-downloads YouTube's player code and re-solves its JavaScript
          // challenges before a single byte of audio arrives, which is slow
          // on a phone. refreshYtDlpCache clears it for a retry after a 403.
          final ytdlpCache = await getYtDlpCacheDirectory();
          const channel = MethodChannel('peerm/ytdlp');
          await channel.invokeMethod('downloadAudioFast', {
            'url': 'https://www.youtube.com/watch?v=$videoId',
            'outputPath': tempPart.path,
            'processId': processId,
            'format': getAudioFormatArg(),
            'cacheDir': ytdlpCache.path,
          }).timeout(const Duration(seconds: 120));

          final cached = await getCachedFile(videoId);
          if (cached != null) {
            final len = await cached.length();
            _cachedVideoIds.add(videoId);
            _setCachedTotalBytes(_cachedTotalBytes + len);
            unawaited(enforceCacheQuota());
            stopwatch.stop();
            DebugLog.write(
              '[cache] Android yt-dlp cached $videoId in ${stopwatch.elapsedMilliseconds}ms (${(len / 1024).round()} KB)',
            );
            if (!completer.isCompleted) {
            completer.complete(cached);
          }
          }
          if (completer.isCompleted) {
            return await completer.future;
          }
        } catch (e) {
          final isCancellation = (e is PlatformException && (e.code == 'cancelled' || e.message?.contains('cancelled') == true)) ||
              _activeProcessId != processId ||
              !_inFlightDownloads.containsKey(videoId);
          if (isCancellation) {
            DebugLog.write('[cache] Android yt-dlp download cancelled for $videoId');
          } else {
            DebugLog.write('[cache] Android yt-dlp FAILED for $videoId: $e');
            recordFailure(
              e is PlatformException
                  ? '${e.code}: ${e.message ?? ''}'
                  : '$e',
            );
          }
          // Drop the half-written file so it can never be served as a cache hit.
          try {
            if (await tempPart.exists()) await tempPart.delete();
          } catch (_) {}
        } finally {
          _androidFetchVideoIds.remove(processId);
          _androidFetchPaths.remove(processId);
          if (_activeProcessId == processId) {
            _activeProcessId = null;
          }
        }
        // On Android, the embedded engine is the sole resolver; never fall through to desktop
        if (!kIsWeb && Platform.isAndroid) {
          if (!completer.isCompleted) {
            completer.complete(null);
          }
          return await completer.future;
        }
      }

      // Desktop yt-dlp engine with client emulation and robust audio format selection
      var bin = await YoutubeService.ytDlpPath();
      if (bin == null && !kIsWeb && !Platform.isAndroid) {
        DebugLog.write('[cache] Desktop yt-dlp not found on disk, auto-downloading dependency...');
        bin = await YoutubeService.ensureYtDlpAvailable();
      }
      if (bin != null) {
        final binPath = bin;
        final outputTemplate = p.join(dir.path, '%(id)s.%(ext)s');
        final ytdlpCache = await getYtDlpCacheDirectory();
        const timeoutDuration = Duration(seconds: 120);
        var linkPublished = false;
        var cancelled = false;

        /// One desktop fetch: takes the pre-booted spare when available (it
        /// already paid the ~2 s yt-dlp startup) or spawns on demand, feeds it
        /// the URL over stdin and waits for the process to finish.
        Future<File?> fetchWithYtDlp(List<String> baseArgs) async {
          final process = await YtDlpPrewarmer.instance.startFetch(
            url: 'https://www.youtube.com/watch?v=$videoId',
            bin: binPath,
            baseArgs: baseArgs,
            outputTemplate: outputTemplate,
          );
          if (process == null) {
            DebugLog.write('[cache] Could not start yt-dlp for $videoId');
            recordFailure('could not start yt-dlp');
            await _deletePartialArtifacts(videoId);
            return null;
          }
          DebugLog.write('[cache] Started desktop yt-dlp for $videoId');
          _activeDesktopProcess = process;

          process.stdout
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())
              .listen(
                (line) {
                  final stream = parseStreamLine(line);
                  if (stream != null) {
                    DebugLog.write('[cache] Direct stream link ready for $videoId');
                    linkPublished = true;
                    _publishResolvedStream(videoId, stream);
                  }
                },
                onError: (_) {},
              );
          final stderrBuffer = StringBuffer();
          process.stderr.transform(utf8.decoder).listen(
            (data) {
              stderrBuffer.write(data);
            },
            onError: (_) {},
          );

          int exitCode = -1;
          try {
            exitCode = await process.exitCode.timeout(timeoutDuration);
          } on TimeoutException {
            DebugLog.write(
              '[cache] Desktop yt-dlp timed out for $videoId after ${timeoutDuration.inSeconds}s, killing process',
            );
            recordFailure('download timed out after ${timeoutDuration.inSeconds}s');
            YoutubeService.killProcessTree(process.pid);
            await _deletePartialArtifacts(videoId);
            rethrow;
          } finally {
            if (_activeDesktopProcess == process) {
              _activeDesktopProcess = null;
            } else {
              // _killActiveDesktopEngine already dropped it: a cancel.
              cancelled = true;
            }
          }

          if (exitCode != 0) {
            final err = stderrBuffer.toString().trim();
            if (err.isNotEmpty) {
              DebugLog.write('[cache] yt-dlp exit=$exitCode stderr: $err');
            }
            recordFailure(err.isNotEmpty ? err : 'yt-dlp exited with code $exitCode');
            // The process was killed or failed: a truncated file may be sitting
            // at the final name (--no-part). Drop it so it is never adopted as
            // a valid cache hit; the next attempt refetches cleanly.
            await _deletePartialArtifacts(videoId);
            return null;
          }
          return getCachedFile(videoId);
        }

        var fetched = await fetchWithYtDlp(_desktopStreamArgs(ytdlpCache.path));
        // Retry only a fetch that is still wanted and failed for a reason the
        // player code can fix: not for a gone video, a dead network or a
        // missing yt-dlp, and never after a cancel or a newer request.
        final failureKind = _lastFetchFailures[videoId]?.kind;
        final stillWanted = !cancelled &&
            token == _downloadInvocationToken &&
            !(isPreload && preloadSeq != _slidingWindowSequence) &&
            _activeDownloadingVideoId == videoId;
        if (fetched == null &&
            !linkPublished &&
            stillWanted &&
            (failureKind == null ||
                failureKind == StreamFetchFailureKind.unknown ||
                failureKind == StreamFetchFailureKind.blocked)) {
          DebugLog.write('[cache] No link without the player code for $videoId, retrying with it');
          fetched = await fetchWithYtDlp(_desktopStreamArgs(ytdlpCache.path, skipPlayerJs: false));
        }

        if (fetched != null) {
          final len = await fetched.length();
          _setCachedTotalBytes(_cachedTotalBytes + len);
          unawaited(enforceCacheQuota());
          stopwatch.stop();
          DebugLog.write(
            '[cache] yt-dlp cached $videoId in ${stopwatch.elapsedMilliseconds}ms (${(len / 1024).round()} KB) at ${fetched.path}',
          );
          if (!completer.isCompleted) {
            completer.complete(fetched);
          }
          return fetched;
        }
      } else if (!kIsWeb && !Platform.isAndroid) {
        DebugLog.write('[cache] yt-dlp binary not found on desktop');
        recordFailure('yt-dlp is missing on this device');
      }

      if (!completer.isCompleted) {
        DebugLog.write('[cache] Download failed for $videoId after ${stopwatch.elapsedMilliseconds}ms');
        if (!failureRecorded) {
          recordFailure('stream download failed');
        }
      }
    } catch (e) {
      DebugLog.write('[cache] ensureStreamCached error for $videoId: $e');
      if (!failureRecorded) {
        recordFailure('$e');
      }
    } finally {
      _resolvedStreams.remove(videoId);
      if (_activeDownloadingVideoId == videoId) {
        _activeDownloadingVideoId = null;
        _isActiveDownloadPreload = false;
        _activeProcessId = null;
        _activeDesktopProcess = null;
      }
      if (!completer.isCompleted) {
        completer.complete(null);
      }
      _inFlightDownloads.remove(videoId);
      // Boot the next spare while the app is otherwise idle again, so the
      // startup cost stays off the next fetch's critical path.
      unawaited(prewarmDesktopYtDlp());
    }
    return null;
  }

  /// Trims stream cache directory to remain strictly under the [maxCacheBytes] and
  /// [maxTrackCount] quota, and purges stale temporary download artifacts.
  static Future<void> enforceCacheQuota() async {
    try {
      final dir = await getCacheDirectory();
      final entities = await dir.list().toList();
      final files = entities.whereType<File>().toList();
      int totalSize = 0;
      final fileStats = <File, FileStat>{};
      final now = DateTime.now();

      for (final f in files) {
        final stat = await f.stat();
        final name = p.basename(f.path);

        // Temporary and partial files are not completed cached tracks.
        // Clean up dangling temp files older than 2 minutes, and skip active ones.
        if (name.contains('.tmp.') || name.contains('.part.') || name.startsWith('tmp_')) {
          if (now.difference(stat.modified) > const Duration(minutes: 2)) {
            try {
              await f.delete();
            } catch (_) {}
          }
          continue;
        }

        fileStats[f] = stat;
        totalSize += stat.size;
      }

      if (totalSize <= maxCacheBytes && fileStats.length <= maxTrackCount) {
        _setCachedTotalBytes(totalSize);
        return;
      }

      // Sort by last accessed / modified (oldest first)
      final validFiles = fileStats.keys.toList()
        ..sort((a, b) {
          final statA = fileStats[a]!;
          final statB = fileStats[b]!;
          return statA.modified.compareTo(statB.modified);
        });

      int currentTrackCount = validFiles.length;
      for (final f in validFiles) {
        if (totalSize <= targetEvictionBytes && currentTrackCount <= maxTrackCount) break;
        final rawName = p.basenameWithoutExtension(f.path);
        final vId = rawName.contains('.') ? rawName.split('.').first : rawName;
        if (_activeQueueVideoIds.contains(vId)) continue;

        final size = fileStats[f]?.size ?? 0;
        try {
          _cachedVideoIds.remove(vId);
          await f.delete();
          totalSize -= size;
          currentTrackCount--;
          DebugLog.write('[cache] Evicted old unqueued track: $vId (${(size / 1024).round()} KB)');
        } catch (_) {}
      }
      _setCachedTotalBytes(totalSize);
    } catch (e) {
      debugPrint('[StreamCacheManager] Quota enforcement error: $e');
    }
  }

  /// Saves an ephemeral stream track permanently into the user's local [library].
  /// If already in stream cache, copies the file into library instantly in 0 ms.
  static Future<Song?> saveToLibrary(Song streamSong, LibraryService library) async {
    try {
      final videoId = streamSong.id.replaceFirst('stream_', '');
      final cached = await getCachedFile(videoId);

      if (cached != null && await cached.exists()) {
        final base64Art = await YoutubeService.downloadArtworkAsBase64(
          streamSong.artwork,
          videoId: videoId,
        );
        // Fast 0 ms promotion from stream cache
        final song = await library.addScrapedFile(
          cached,
          title: streamSong.title,
          artwork: base64Art ?? streamSong.artwork,
        );
        if (song != null) return song;
      }

      final ytUrl = 'https://www.youtube.com/watch?v=$videoId';
      final youtubeService = YoutubeService();

      return await youtubeService.scrapeAndAddWithYtDlp(
        library,
        ytUrl,
      );
    } catch (e) {
      debugPrint('[StreamCacheManager] Failed to save stream song: $e');
      return null;
    }
  }

  /// Purges all cached radio and streaming audio files and clears in-memory caches.
  static Future<void> clearCache() async {
    cancelActiveDownload();
    try {
      final dir = await getCacheDirectory();
      if (await dir.exists()) {
        final entities = await dir.list().toList();
        for (final entity in entities) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
      _cachedVideoIds.clear();
      _setCachedTotalBytes(0);
      DebugLog.write('[stream] Cleared all radio and streaming cache files');
    } catch (e) {
      DebugLog.write('[stream] clearCache error: $e');
    }
  }

  /// Clean up resources on shutdown.
  static void dispose() {
    cancelActiveDownload();
    cancelPreload();
  }
}

