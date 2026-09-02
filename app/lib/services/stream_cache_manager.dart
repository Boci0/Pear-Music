import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';
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
  static final Lock _nativeDownloadLock = Lock();
  static int _slidingWindowSequence = 0;
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
          final id = p.basenameWithoutExtension(name);
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

  /// Quick cache-only check: returns the cached file if it exists, null otherwise.
  static Future<File?> getCachedFile(String videoId) async {
    final dir = await getCacheDirectory();
    for (final ext in ['m4a', 'mp4', 'webm', 'opus', 'ogg', 'mp3']) {
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
    return null;
  }

  static String? _activePreloadProcessId;
  static String? _activePreloadVideoId;
  static Process? _activePreloadDesktopProcess;

  /// Cancels any active background preload sequence immediately.
  static void cancelPreload({String? exceptVideoId}) {
    _slidingWindowSequence++;
    if (exceptVideoId != null && _activePreloadVideoId == exceptVideoId) {
      DebugLog.write('[preload] Preserving active in-flight download for $exceptVideoId');
      return;
    }
    final activeId = _activePreloadProcessId;
    if (activeId != null && YoutubeService.isEmbeddedYtDlpSupported) {
      _activePreloadProcessId = null;
      _activePreloadVideoId = null;
      try {
        const MethodChannel('peerm/ytdlp').invokeMethod('cancel', {'processId': activeId});
      } catch (_) {}
    }
    final desktopProc = _activePreloadDesktopProcess;
    if (desktopProc != null) {
      _activePreloadDesktopProcess = null;
      _activePreloadVideoId = null;
      try {
        desktopProc.kill();
      } catch (_) {}
    }
    DebugLog.write('[preload] cancelPreload() called, new sequence=$_slidingWindowSequence');
  }

  /// Sequentially pre-downloads a tight 1-track lookahead window
  /// in the background using a single-queue worker to enable instant 0ms playback.
  static void preloadSlidingWindow(
    List<String> videoIds, {
    void Function(String videoId)? onTrackCached,
  }) {
    final seq = ++_slidingWindowSequence;
    unawaited(() async {
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
    }());
  }

  /// Ensures the audio stream for [videoId] is downloaded into the local cache
  /// using yt-dlp exclusively with client emulation to bypass all rate limits and bot challenges.
  static Future<File?> ensureStreamCached(String videoId, {bool isPreload = false}) async {
    final existing = await getCachedFile(videoId);
    if (existing != null) {
      DebugLog.write('[cache] Disk cache HIT for $videoId (0ms)');
      return existing;
    }

    // Single-flight deduplication
    if (_inFlightDownloads.containsKey(videoId)) {
      DebugLog.write('[cache] Joining in-flight download for $videoId');
      return await _inFlightDownloads[videoId]!.future;
    }

    final completer = Completer<File?>();
    _inFlightDownloads[videoId] = completer;
    final stopwatch = Stopwatch()..start();

    try {
      final dir = await getCacheDirectory();

      // Android embedded yt-dlp
      if (YoutubeService.isEmbeddedYtDlpSupported) {
        final tempPart = File(p.join(dir.path, '$videoId.m4a'));
        final processId = 'peerm-fast-$videoId-${DateTime.now().millisecondsSinceEpoch}';
        if (isPreload) {
          _activePreloadProcessId = processId;
          _activePreloadVideoId = videoId;
        }
        try {
          DebugLog.write('[cache] Android embedded yt-dlp downloading $videoId');
          const channel = MethodChannel('peerm/ytdlp');
          await channel.invokeMethod('downloadAudioFast', {
            'url': 'https://www.youtube.com/watch?v=$videoId',
            'outputPath': tempPart.path,
            'processId': processId,
          }).timeout(const Duration(seconds: 45));

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
          if (isPreload && _activePreloadProcessId == processId) {
            _activePreloadProcessId = null;
            _activePreloadVideoId = null;
          }
        }
      }

      // Desktop yt-dlp engine with robust audio format selection
      final bin = await YoutubeService.ytDlpPath();
      if (bin != null) {
        DebugLog.write('[cache] Spawning desktop yt-dlp for $videoId');
        final outputTemplate = p.join(dir.path, '$videoId.%(ext)s');
        final args = [
          '-f',
          'ba/ba*/bestaudio/b/best',
          '-o',
          outputTemplate,
          '--no-playlist',
          '--no-part',
          '--no-mtime',
          '--no-warnings',
          '--no-check-certificates',
          '--force-ipv4',
          '--concurrent-fragments',
          '1',
          '--buffer-size',
          '64k',
          '--http-chunk-size',
          '10M',
          '--socket-timeout',
          '15',
          '--retries',
          '3',
          '--no-cache-dir',
          'https://www.youtube.com/watch?v=$videoId',
        ];

        final process = await Process.start(bin, args);
        if (isPreload) {
          _activePreloadDesktopProcess = process;
          _activePreloadVideoId = videoId;
        }

        final timeoutDuration = isPreload
            ? const Duration(seconds: 35)
            : const Duration(seconds: 50);

        final stderrBuffer = StringBuffer();
        process.stderr.transform(utf8.decoder).listen((data) {
          stderrBuffer.write(data);
        });

        int exitCode = -1;
        try {
          exitCode = await process.exitCode.timeout(timeoutDuration);
        } on TimeoutException {
          DebugLog.write(
            '[cache] Desktop yt-dlp timed out for $videoId after ${timeoutDuration.inSeconds}s, killing process',
          );
          try {
            process.kill();
          } catch (_) {}
          rethrow;
        } finally {
          if (isPreload && _activePreloadDesktopProcess == process) {
            _activePreloadDesktopProcess = null;
            _activePreloadVideoId = null;
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

        // Delete dangling temp files older than 1 minute
        if ((name.contains('.tmp.') || name.contains('.part.') || name.startsWith('tmp_')) &&
            now.difference(stat.modified) > const Duration(minutes: 1)) {
          try {
            await f.delete();
          } catch (_) {}
          continue;
        }

        fileStats[f] = stat;
        totalSize += stat.size;
      }

      if (totalSize <= maxCacheBytes && fileStats.length <= maxTrackCount) return;

      // Sort by last accessed / modified (oldest first)
      final validFiles = fileStats.keys.toList()
        ..sort((a, b) {
          final statA = fileStats[a]!;
          final statB = fileStats[b]!;
          return statA.modified.compareTo(statB.modified);
        });

      for (final f in validFiles) {
        if (totalSize <= targetEvictionBytes && validFiles.length <= maxTrackCount) break;
        final vId = p.basenameWithoutExtension(f.path);
        if (_activeQueueVideoIds.contains(vId)) continue;

        final size = fileStats[f]?.size ?? 0;
        try {
          _cachedVideoIds.remove(vId);
          await f.delete();
          totalSize -= size;
          _cachedTotalBytes = (_cachedTotalBytes - size).clamp(0, 1 << 62);
          DebugLog.write('[cache] Evicted old unqueued track: $vId (${(size / 1024).round()} KB)');
        } catch (_) {}
      }
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
        _streamUrlPrefetchCache.remove(videoId);
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
          '-f', 'ba/ba*/bestaudio/b/best',
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
    try {
      final bin = await YoutubeService.ytDlpPath() ?? 'yt-dlp';
      final res = await Process.run(bin, [...args, url]).timeout(timeout);
      if (res.exitCode == 0) {
        final out = res.stdout.toString().trim();
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
    }
    return null;
  }

  /// Purges all cached radio and streaming audio files and clears in-memory caches.
  static Future<void> clearCache() async {
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
    _ytExplode?.close();
    _ytExplode = null;
  }
}

class _CachedStreamUrl {
  final String url;
  final DateTime expiresAt;

  const _CachedStreamUrl(this.url, this.expiresAt);
}

