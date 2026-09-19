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

/// High-speed ephemeral radio cache manager.
/// Streams audio directly into local disk files using optimized audio-only extractors.
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
          }
          // Drop the half-written file so it can never be served as a cache hit.
          try {
            if (await tempPart.exists()) await tempPart.delete();
          } catch (_) {}
        } finally {
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
        DebugLog.write('[cache] Spawning desktop yt-dlp for $videoId');
        final outputTemplate = p.join(dir.path, '$videoId.%(ext)s');
        final ytdlpCache = await getYtDlpCacheDirectory();
        final args = [
          '-f',
          getAudioFormatArg(),
          '--cache-dir',
          ytdlpCache.path,
          '--extractor-args',
          'youtube:skip=webpage,authcheck,translated_subs,hls',
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
          await _deletePartialArtifacts(videoId);
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
          // The process was killed or failed: a truncated file may be sitting
          // at the final name (--no-part). Drop it so it is never adopted as
          // a valid cache hit; the next attempt refetches cleanly.
          await _deletePartialArtifacts(videoId);
        } else {
          final cached = await getCachedFile(videoId);
          if (cached != null) {
            final len = await cached.length();
            _setCachedTotalBytes(_cachedTotalBytes + len);
            unawaited(enforceCacheQuota());
            stopwatch.stop();
            DebugLog.write(
              '[cache] yt-dlp cached $videoId in ${stopwatch.elapsedMilliseconds}ms (${(len / 1024).round()} KB) at ${cached.path}',
            );
            if (!completer.isCompleted) {
              completer.complete(cached);
            }
            return cached;
          }
        }
      } else if (!kIsWeb && !Platform.isAndroid) {
        DebugLog.write('[cache] yt-dlp binary not found on desktop');
      }

      if (!completer.isCompleted) {
        DebugLog.write('[cache] Download failed for $videoId after ${stopwatch.elapsedMilliseconds}ms');
      }
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

