import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/song.dart';
import 'debug_log.dart';
import 'library_service.dart';
import 'youtube_service.dart';

/// High-speed ephemeral radio cache manager.
/// Streams audio directly into local disk files using optimized audio-only extractors.
class StreamCacheManager {
  static const int maxCacheBytes = 500 * 1024 * 1024; // 500 MB cap
  static const int targetEvictionBytes = 400 * 1024 * 1024; // prune to 400 MB
  static const int maxTrackCount = 100;

  /// High-efficiency default audio format selector (~128-160 kbps AAC/Opus).
  static const String audioFormatArg = 'ba/ba*/bestaudio/b/best';
  static String getAudioFormatArg() => audioFormatArg;

  static Set<String> _activeQueueVideoIds = {};
  /// Protects all tracks currently in the active queue from being evicted.
  static void setActiveQueueVideoIds(Iterable<String> ids) {
    _activeQueueVideoIds = ids.toSet();
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

  static YoutubeExplode? _ytExplode;
  static YoutubeExplode get _yt => _ytExplode ??= YoutubeExplode();

  static final Map<String, Completer<File?>> _inFlightDownloads = {};
  static final Set<String> _cachedVideoIds = {};
  static final Map<String, _CachedStreamUrl> _streamUrlMemoryCache = {};
  static int _slidingWindowSequence = 0;
  static int _downloadInvocationToken = 0;
  // In-flight / completed direct stream URL resolutions, so a prefetch
  // started while the previous track plays satisfies the next track's
  // immediate look-up with 0ms of yt-dlp latency.
  static final Map<String, Future<String?>> _streamUrlPrefetchCache = {};
  // Consecutive resolution failures — when >= 3, activates fast-fail mode
  // (4s timeout instead of 8s) so a rate-limited YouTube connection doesn't
  // hang the queue for 40+ seconds per track.
  static int _consecutiveFailures = 0;
  static bool get isFastFailMode => _consecutiveFailures >= 3;
  static int _cachedTotalBytes = 0;

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
    try {
      final dir = await getCacheDirectory();
      final files = await dir.list().where((e) => e is File).cast<File>().toList();
      int total = 0;
      for (final f in files) {
        final name = p.basename(f.path);
        if (name.contains('.tmp.') || name.contains('.part.') || name.startsWith('tmp_')) {
          try {
            await f.delete();
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
      _cachedTotalBytes = total;
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

  static String? _activeDownloadingVideoId;
  static bool _isActiveDownloadPreload = false;
  static String? _activeProcessId;
  static Process? _activeDesktopProcess;

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
      final desktopProc = _activeDesktopProcess;
      if (desktopProc != null) {
        _activeDesktopProcess = null;
        try {
          YoutubeService.killProcessTree(desktopProc.pid);
        } catch (_) {}
      }
      final abandoned = _activeDownloadingVideoId;
      if (abandoned != null && _inFlightDownloads.containsKey(abandoned)) {
        if (!_inFlightDownloads[abandoned]!.isCompleted) {
          _inFlightDownloads[abandoned]?.complete(null);
        }
        _inFlightDownloads.remove(abandoned);
      }
      _activeDownloadingVideoId = null;
      _isActiveDownloadPreload = false;
    }
    DebugLog.write('[preload] cancelPreload() called, new sequence=$_slidingWindowSequence');
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
      final desktopProc = _activeDesktopProcess;
      if (desktopProc != null) {
        _activeDesktopProcess = null;
        try {
          YoutubeService.killProcessTree(desktopProc.pid);
        } catch (_) {}
      }
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
            final file = await ensureStreamCached(id, isPreload: true);
            if (seq != _slidingWindowSequence) break;
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

  /// Ensures the audio stream for [videoId] is downloaded into the local cache
  /// using yt-dlp exclusively with client emulation to bypass all rate limits and bot challenges.
  /// Strictly enforces single-concurrency to prevent multiple downloads from splitting bandwidth.
  static Future<File?> ensureStreamCached(String videoId, {bool isPreload = false}) async {
    final token = ++_downloadInvocationToken;
    final preloadSeq = _slidingWindowSequence;

    final existing = await getCachedFile(videoId);
    if (existing != null) {
      DebugLog.write('[cache] Disk cache HIT for $videoId (0ms)');
      return existing;
    }
    if (token != _downloadInvocationToken) return null;
    if (isPreload && preloadSeq != _slidingWindowSequence) return null;

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
      if (_activeDesktopProcess != null) {
        YoutubeService.killProcessTree(_activeDesktopProcess!.pid);
        _activeDesktopProcess = null;
      }
      _activeDownloadingVideoId = null;
      _isActiveDownloadPreload = false;
    }

    _activeDownloadingVideoId = videoId;
    _isActiveDownloadPreload = isPreload;

    final completer = Completer<File?>();
    _inFlightDownloads[videoId] = completer;
    final stopwatch = Stopwatch()..start();

    try {
      final dir = await getCacheDirectory();

      // Android embedded yt-dlp
      if (YoutubeService.isEmbeddedYtDlpSupported) {
        final tempPart = File(p.join(dir.path, '$videoId.m4a'));
        final processId = 'peerm-fast-$videoId-${DateTime.now().millisecondsSinceEpoch}';
        _activeProcessId = processId;
        try {
          DebugLog.write('[cache] Android embedded yt-dlp downloading $videoId');
          const channel = MethodChannel('peerm/ytdlp');
          await channel.invokeMethod('downloadAudioFast', {
            'url': 'https://www.youtube.com/watch?v=$videoId',
            'outputPath': tempPart.path,
            'processId': processId,
            'format': getAudioFormatArg(),
          }).timeout(const Duration(seconds: 120));

          final cached = await getCachedFile(videoId);
          if (cached != null) {
            final len = await cached.length();
            _cachedVideoIds.add(videoId);
            _cachedTotalBytes += len;
            unawaited(enforceCacheQuota());
            stopwatch.stop();
            DebugLog.write(
              '[cache] Android yt-dlp cached $videoId in ${stopwatch.elapsedMilliseconds}ms (${(len / 1024).round()} KB)',
            );
            completer.complete(cached);
          }
          if (completer.isCompleted) {
            return await completer.future;
          }
        } catch (e) {
          DebugLog.write('[cache] Android yt-dlp FAILED for $videoId: $e');
        } finally {
          if (_activeProcessId == processId) {
            _activeProcessId = null;
          }
        }
      }

      // Desktop yt-dlp engine with client emulation and robust audio format selection
      final bin = await YoutubeService.ytDlpPath();
      if (bin != null) {
        DebugLog.write('[cache] Spawning desktop yt-dlp for $videoId');
        final outputTemplate = p.join(dir.path, '$videoId.%(ext)s');
        final args = [
          '-f',
          getAudioFormatArg(),
          '-o',
          outputTemplate,
          '--no-playlist',
          '--no-part',
          '--no-mtime',
          '--no-warnings',
          '--no-check-certificates',
          '--quiet',
          '--force-ipv4',
          '--concurrent-fragments',
          '4',
          '--buffer-size',
          '256k',
          '--socket-timeout',
          '10',
          '--retries',
          '2',
          'https://www.youtube.com/watch?v=$videoId',
        ];

        final process = await Process.start(bin, args);
        _activeDesktopProcess = process;

        const timeoutDuration = Duration(seconds: 120);

        process.stdout.drain().catchError((_) => null);
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
          YoutubeService.killProcessTree(process.pid);
          rethrow;
        } finally {
          if (_activeDesktopProcess == process) {
            _activeDesktopProcess = null;
          }
        }

        if (exitCode != 0) {
          final err = stderrBuffer.toString().trim();
          if (err.isNotEmpty) {
            DebugLog.write('[cache] yt-dlp exit=$exitCode stderr: $err');
          }
        }

        final cached = await getCachedFile(videoId);
        if (cached != null) {
          final len = await cached.length();
          _cachedTotalBytes += len;
          unawaited(enforceCacheQuota());
          stopwatch.stop();
          DebugLog.write(
            '[cache] yt-dlp cached $videoId in ${stopwatch.elapsedMilliseconds}ms (${(len / 1024).round()} KB) at ${cached.path}',
          );
          completer.complete(cached);
          return cached;
        }
      } else {
        DebugLog.write('[cache] yt-dlp binary not found on desktop');
      }

      DebugLog.write('[cache] Download failed for $videoId after ${stopwatch.elapsedMilliseconds}ms');
    } catch (e) {
      DebugLog.write('[cache] ensureStreamCached error for $videoId: $e');
    } finally {
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
        _cachedTotalBytes = totalSize;
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
      _cachedTotalBytes = totalSize;
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

  /// Fast-path extraction of direct CDN stream URL with in-memory caching.
  /// Resolves the stream URL so playback can stream directly in RAM with 0 SSD writes.
  ///
  /// Checks the prefetch cache first — if a prefetch for [videoId] is in-flight
  /// or already completed, that Future is awaited directly, eliminating yt-dlp
  /// latency on the hot path.
  static Future<String?> extractDirectStreamUrl(String videoId) async {
    // 1. Fast path: in-memory cache (already resolved)
    final cached = _streamUrlMemoryCache[videoId];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.url;
    }

    // 2. Prefetch path: a background resolution is already running or done
    final prefetchFuture = _streamUrlPrefetchCache[videoId];
    if (prefetchFuture != null) {
      return prefetchFuture;
    }

    // 3. Cold path: resolve now
    return _resolveAndCacheStreamUrl(videoId);
  }

  /// Proactively resolves the stream URL for [videoId] in the background.
  ///
  /// Returns immediately. The resulting Future is stored in [_streamUrlPrefetchCache]
  /// so a subsequent call to [extractDirectStreamUrl] will await the in-flight
  /// resolution instead of starting a new yt-dlp process. This eliminates the
  /// 3–15s gap between tracks when the next song's URL is resolved during the
  /// current song's playback.
  ///
  /// Safe to call repeatedly — only one resolution runs per [videoId].
  static void prefetchStreamUrl(String videoId) {
    if (_streamUrlMemoryCache.containsKey(videoId)) return;
    if (_streamUrlPrefetchCache.containsKey(videoId)) return;

    final future = _resolveAndCacheStreamUrl(videoId);
    _streamUrlPrefetchCache[videoId] = future;

    // Clean up the prefetch entry once resolved (success or failure)
    future.whenComplete(() {
      // Keep the result in _streamUrlMemoryCache (set inside _resolveAndCacheStreamUrl).
      // Remove from prefetch cache after a short delay so the memory cache has time
      // to serve subsequent lookups without re-triggering extraction.
      Future.delayed(const Duration(seconds: 30), () {
        if (_streamUrlPrefetchCache[videoId] == future) {
          _streamUrlPrefetchCache.remove(videoId);
        }
      });
    });
  }

  static void _saveToStreamUrlCache(String videoId, String url) {
    if (_streamUrlMemoryCache.length > 100) {
      final now = DateTime.now();
      _streamUrlMemoryCache.removeWhere((_, cached) => now.isAfter(cached.expiresAt));
      if (_streamUrlMemoryCache.length > 80) {
        final keysToRemove = _streamUrlMemoryCache.keys.take(20).toList();
        for (final k in keysToRemove) {
          _streamUrlMemoryCache.remove(k);
        }
      }
    }
    _streamUrlMemoryCache[videoId] = _CachedStreamUrl(
      url,
      DateTime.now().add(const Duration(hours: 4)),
    );
  }

  /// Core resolution logic — shared by [extractDirectStreamUrl] and [prefetchStreamUrl].
  ///
  /// Tier 1: In-process direct HTTP stream extraction via YoutubeExplode (~150-300ms).
  /// Tier 2: Platform channels / native yt-dlp (Android) or desktop yt-dlp process.
  ///
  /// Tracks consecutive failures and activates fast-fail mode (>= 3 failures)
  /// which shortens timeouts so a rate-limited YouTube connection doesn't hang the queue.
  static Future<String?> _resolveAndCacheStreamUrl(String videoId) async {
    final fastFail = isFastFailMode;

    // Tier 1: Fast in-process HTTP resolution via YoutubeExplode
    try {
      final manifest = await _yt.videos.streamsClient
          .getManifest(videoId)
          .timeout(Duration(seconds: fastFail ? 3 : 5));
      final audioStreams = manifest.audioOnly;
      if (audioStreams.isNotEmpty) {
        final mp4Streams = audioStreams.where((s) => s.container == StreamContainer.mp4).toList();
        final audioStream = mp4Streams.isNotEmpty
            ? mp4Streams.withHighestBitrate()
            : audioStreams.withHighestBitrate();
        final streamUrl = audioStream.url.toString();
        if (streamUrl.startsWith('http')) {
          _saveToStreamUrlCache(videoId, streamUrl);
          _consecutiveFailures = 0;
          DebugLog.write('[stream] Fast in-process resolution succeeded for $videoId');
          return streamUrl;
        }
      }
    } catch (e) {
      DebugLog.write('[stream] In-process stream resolution skipped/failed for $videoId: $e');
    }

    // Tier 2: Android embedded yt-dlp platform channel
    final url = 'https://www.youtube.com/watch?v=$videoId';
    if (!kIsWeb && Platform.isAndroid) {
      try {
        const channel = MethodChannel('peerm/ytdlp');
        final res = await channel.invokeMethod<String>('getStreamUrl', {'url': url})
            .timeout(Duration(seconds: fastFail ? 6 : 10));
        if (res != null && res.startsWith('http')) {
          _saveToStreamUrlCache(videoId, res);
          _consecutiveFailures = 0;
          return res;
        }
      } catch (_) {}
    } else if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      // Tier 3: Desktop yt-dlp fallback
      final result = await _runYtDlp(
        url,
        [
          '-g',
          '-f', getAudioFormatArg(),
          '--no-playlist',
          '--force-ipv4',
          '--no-warnings',
          '--no-check-certificates',
          '--no-call-home',
          '--quiet',
          '--socket-timeout', '6',
          '--retries', '1',
          '--fragment-retries', '1',
        ],
        fastFail: fastFail,
      );

      if (result != null) {
        _saveToStreamUrlCache(videoId, result);
        _consecutiveFailures = 0;
        return result;
      }

      // Tier 3 Fallback: Relaxed format
      DebugLog.write('[stream] Primary yt-dlp failed for $videoId, trying relaxed fallback...');
      final fallback = await _runYtDlp(
        url,
        [
          '-g',
          '-f', 'bestaudio/ba/b/best',
          '--no-playlist',
          '--force-ipv4',
          '--no-warnings',
          '--no-check-certificates',
          '--no-call-home',
          '--quiet',
          '--socket-timeout', '8',
        ],
        fastFail: fastFail,
      );

      if (fallback != null) {
        _saveToStreamUrlCache(videoId, fallback);
        _consecutiveFailures = 0;
        DebugLog.write('[stream] Fallback succeeded for $videoId');
        return fallback;
      }
    }

    // All attempts failed
    _consecutiveFailures++;
    if (fastFail) {
      DebugLog.write('[stream] Fast-fail resolution failed for $videoId (failure $_consecutiveFailures)');
    }
    return null;
  }

  /// Resets the consecutive-failure counter. Call when playback resumes after
  /// a rate-limit event clears (e.g. user retries, network changes).
  static void resetFailureCounter() {
    _consecutiveFailures = 0;
  }

  /// Runs a single yt-dlp invocation with the given arguments and returns the
  /// first HTTP URL from stdout, or null on failure.
  static Future<String?> _runYtDlp(
    String url,
    List<String> args, {
    bool fastFail = false,
  }) async {
    final timeout = fastFail
        ? const Duration(seconds: 4)
        : Duration(seconds: args.contains('--quiet') ? 8 : 6);
    Process? proc;
    try {
      final bin = await YoutubeService.ytDlpPath() ?? 'yt-dlp';
      proc = await Process.start(bin, [...args, url]);
      final outBuf = StringBuffer();
      final outSub = proc.stdout.transform(utf8.decoder).listen(
        outBuf.write,
        onError: (_) {},
      );
      proc.stderr.drain().catchError((_) => null);
      int exitCode;
      try {
        exitCode = await proc.exitCode.timeout(timeout);
      } on TimeoutException {
        YoutubeService.killProcessTree(proc.pid);
        rethrow;
      } finally {
        await outSub.cancel();
      }
      if (exitCode == 0) {
        final out = outBuf.toString().trim();
        final lines = out
            .split(RegExp(r'[\r\n]+'))
            .map((l) => l.trim())
            .where((l) => l.startsWith('http'))
            .toList();
        if (lines.isNotEmpty) {
          return lines.first;
        }
      }
    } catch (e) {
      DebugLog.write('[stream] yt-dlp attempt failed: $e');
    } finally {
      if (proc != null) {
        YoutubeService.killProcessTree(proc.pid);
      }
    }
    return null;
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
      _streamUrlMemoryCache.clear();
      _streamUrlPrefetchCache.clear();
      _cachedTotalBytes = 0;
      DebugLog.write('[stream] Cleared all radio and streaming cache files');
    } catch (e) {
      DebugLog.write('[stream] clearCache error: $e');
    }
  }

  /// Clean up resources on shutdown.
  static void dispose() {
    cancelActiveDownload();
    cancelPreload();
    _ytExplode?.close();
    _ytExplode = null;
  }
}

class _CachedStreamUrl {
  final String url;
  final DateTime expiresAt;

  const _CachedStreamUrl(this.url, this.expiresAt);
}

