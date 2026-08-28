import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import 'debug_log.dart';
import 'innertube_player_service.dart';
import 'library_service.dart';
import 'youtube_service.dart';

/// High-speed ephemeral radio cache manager.
/// Streams audio directly into local disk files using optimized audio-only extractors.
class StreamCacheManager {
  static const int maxCacheBytes = 150 * 1024 * 1024; // 150 MB cap (~45-50 songs)
  static const int targetEvictionBytes = 100 * 1024 * 1024; // prune to 100 MB
  static const int maxTrackCount = 50;

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

  static final Map<String, Completer<File?>> _inFlightDownloads = {};
  static final Set<String> _cachedVideoIds = {};
  static int _slidingWindowSequence = 0;

  /// Pre-scans existing cache files on app launch for instantaneous lookup.
  static Future<void> warmUp() async {
    try {
      final dir = await getCacheDirectory();
      final files = await dir.list().where((e) => e is File).cast<File>().toList();
      for (final f in files) {
        final name = p.basename(f.path);
        if (name.contains('.tmp.') || name.contains('.part.') || name.startsWith('tmp_')) {
          try {
            await f.delete();
          } catch (_) {}
          continue;
        }
        if (await f.length() > 50000) {
          final id = p.basenameWithoutExtension(name);
          _cachedVideoIds.add(id);
        }
      }
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
    for (final ext in ['m4a', 'mp4', 'webm']) {
      final f = File(p.join(dir.path, '$videoId.$ext'));
      if (await f.exists() && (await f.length()) > 50000) {
        _cachedVideoIds.add(videoId);
        return f;
      }
    }
    return null;
  }

  static final Map<String, _CachedStreamUrl> _streamUrlMemoryCache = {};

  /// Sequentially pre-resolves direct stream URLs for upcoming tracks into RAM.
  /// Keeps playback seamless and instant with ZERO SSD writes.
  static void preloadSlidingWindow(
    List<String> videoIds, {
    void Function(String videoId)? onTrackCached,
  }) {
    final seq = ++_slidingWindowSequence;
    unawaited(() async {
      // Pre-resolve direct stream URLs for the immediate upcoming 2 tracks
      for (final id in videoIds.take(2)) {
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
        final cachedUrl = _streamUrlMemoryCache[id];
        if (cachedUrl != null && DateTime.now().isBefore(cachedUrl.expiresAt)) {
          onTrackCached?.call(id);
          continue;
        }
        try {
          DebugLog.write('[preload] Pre-resolving stream URL in RAM: $id');
          final url = await extractDirectStreamUrl(id);
          if (seq != _slidingWindowSequence) break;
          if (url != null) {
            DebugLog.write('[preload] Pre-resolved stream URL ready in RAM: $id');
            onTrackCached?.call(id);
          }
        } catch (_) {}
      }
    }());
  }

  /// Ensures the audio stream for [videoId] is downloaded into the local cache.
  /// Prioritizes fast Innertube direct HTTP stream piping (<1s) over heavy yt-dlp process execution.
  static Future<File?> ensureStreamCached(String videoId) async {
    final existing = await getCachedFile(videoId);
    if (existing != null) {
      DebugLog.write('[cache] Disk cache HIT for $videoId (0ms)');
      return existing;
    }

    // Single-flight deduplication
    if (_inFlightDownloads.containsKey(videoId)) {
      return await _inFlightDownloads[videoId]!.future;
    }

    final completer = Completer<File?>();
    _inFlightDownloads[videoId] = completer;
    final stopwatch = Stopwatch()..start();

    try {
      final dir = await getCacheDirectory();
      final targetFile = File(p.join(dir.path, '$videoId.m4a'));
      final tempPart = File(p.join(dir.path, '$videoId.part.m4a'));

      if (await tempPart.exists()) {
        try {
          await tempPart.delete();
        } catch (_) {}
      }

      // Method 1: High-speed Innertube direct HTTP stream pipe (~150-500ms)
      try {
        DebugLog.write('[stream] Resolving Innertube direct stream: $videoId');
        final streamInfo = await InnertubePlayerService.resolveAudioStream(videoId);
        if (streamInfo != null && streamInfo.url.startsWith('http')) {
          final client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 5)
            ..idleTimeout = const Duration(seconds: 12);
          final req = await client.getUrl(Uri.parse(streamInfo.url));
          req.headers.set(
            'User-Agent',
            'com.google.android.apps.youtube.music/6.42.52 (Linux; U; Android 14)',
          );
          req.headers.set('Referer', 'https://music.youtube.com/');
          final resp = await req.close().timeout(const Duration(seconds: 12));

          if (resp.statusCode == 200 || resp.statusCode == 206) {
            final sink = tempPart.openWrite();
            await resp.pipe(sink);
            final len = await tempPart.exists() ? await tempPart.length() : 0;
            if (len > 50000) {
              if (await targetFile.exists()) {
                try {
                  await targetFile.delete();
                } catch (_) {}
              }
              await tempPart.rename(targetFile.path);
              _cachedVideoIds.add(videoId);
              unawaited(enforceCacheQuota());
              stopwatch.stop();
              DebugLog.write(
                '[stream] Innertube direct pipe cached $videoId in ${stopwatch.elapsedMilliseconds}ms (${(len / 1024).round()} KB)',
              );
              completer.complete(targetFile);
              return targetFile;
            }
          }
        }
      } catch (e) {
        DebugLog.write('[stream] Innertube direct pipe failed for $videoId: $e');
      }

      // Method 2: Android native embedded yt-dlp fast audio download
      if (YoutubeService.isEmbeddedYtDlpSupported) {
        try {
          DebugLog.write('[fallback] Trying Android embedded yt-dlp: $videoId');
          const channel = MethodChannel('peerm/ytdlp');
          final processId = 'peerm-fast-$videoId-${DateTime.now().millisecondsSinceEpoch}';
          final res = await channel.invokeMethod('downloadAudioFast', {
            'url': 'https://www.youtube.com/watch?v=$videoId',
            'outputPath': tempPart.path,
            'processId': processId,
          }).timeout(const Duration(seconds: 45));

          final len = await tempPart.exists() ? await tempPart.length() : 0;
          if (len > 50000) {
            if (await targetFile.exists()) {
              try {
                await targetFile.delete();
              } catch (_) {}
            }
            await tempPart.rename(targetFile.path);
            _cachedVideoIds.add(videoId);
            unawaited(enforceCacheQuota());
            stopwatch.stop();
            DebugLog.write(
              '[fallback] Android yt-dlp cached $videoId in ${stopwatch.elapsedMilliseconds}ms (${(len / 1024).round()} KB)',
            );
            completer.complete(targetFile);
            return targetFile;
          }
        } catch (e) {
          DebugLog.write('[fallback] Android yt-dlp failed for $videoId: $e');
        }
      }

      // Method 3: Desktop local yt-dlp fallback (single fragment, bounded sockets)
      try {
        final bin = await YoutubeService.ytDlpPath();
        if (bin != null) {
          DebugLog.write('[fallback] Spawning desktop yt-dlp fallback: $videoId');
          final res = await Process.run(bin, [
            '-f',
            'bestaudio[abr<=128][ext=m4a]/bestaudio[abr<=128]/bestaudio[ext=m4a]/bestaudio/ba/best',
            '-o',
            tempPart.path,
            '--no-playlist',
            '--no-part',
            '--no-mtime',
            '--no-warnings',
            '--no-check-certificates',
            '--force-ipv4',
            '--concurrent-fragments',
            '1',
            '--socket-timeout',
            '10',
            '--no-cache-dir',
            '--extractor-args',
            'youtube:player_skip=configs,webpage;player_client=android,web',
            'https://www.youtube.com/watch?v=$videoId',
          ]).timeout(const Duration(seconds: 25));

          final len = await tempPart.exists() ? await tempPart.length() : 0;
          if (res.exitCode == 0 && len > 50000) {
            if (await targetFile.exists()) {
              try {
                await targetFile.delete();
              } catch (_) {}
            }
            await tempPart.rename(targetFile.path);
            _cachedVideoIds.add(videoId);
            unawaited(enforceCacheQuota());
            stopwatch.stop();
            DebugLog.write(
              '[fallback] Desktop yt-dlp cached $videoId in ${stopwatch.elapsedMilliseconds}ms (${(len / 1024).round()} KB)',
            );
            completer.complete(targetFile);
            return targetFile;
          }
        }
      } catch (e) {
        DebugLog.write('[fallback] Desktop yt-dlp failed for $videoId: $e');
      }
    } catch (e) {
      DebugLog.write('[stream] ensureStreamCached error for $videoId: $e');
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
        final size = fileStats[f]?.size ?? 0;
        try {
          final vId = p.basenameWithoutExtension(f.path);
          _cachedVideoIds.remove(vId);
          await f.delete();
          totalSize -= size;
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
        // Fast 0 ms promotion from stream cache
        final song = await library.addScrapedFile(
          cached,
          title: streamSong.title,
          artwork: streamSong.artwork,
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

  /// Fast-path extraction of direct CDN stream URL via embedded yt-dlp.
  /// Resolves the stream URL so playback can stream directly in RAM with 0 SSD writes.
  static Future<String?> extractDirectStreamUrl(String videoId) async {
    final cached = _streamUrlMemoryCache[videoId];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.url;
    }

    try {
      final streamInfo = await InnertubePlayerService.resolveAudioStream(videoId);
      if (streamInfo != null && streamInfo.url.startsWith('http')) {
        _streamUrlMemoryCache[videoId] = _CachedStreamUrl(
          streamInfo.url,
          DateTime.now().add(const Duration(hours: 4)),
        );
        return streamInfo.url;
      }
    } catch (_) {}

    final url = 'https://www.youtube.com/watch?v=$videoId';
    if (!kIsWeb && Platform.isAndroid) {
      try {
        const channel = MethodChannel('peerm/ytdlp');
        final res = await channel.invokeMethod<String>('getStreamUrl', {'url': url})
            .timeout(const Duration(seconds: 10));
        if (res != null && res.startsWith('http')) {
          _streamUrlMemoryCache[videoId] = _CachedStreamUrl(
            res,
            DateTime.now().add(const Duration(hours: 4)),
          );
          return res;
        }
      } catch (_) {}
    } else if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      try {
        final res = await Process.run(
          'yt-dlp',
          [
            '-g',
            '-f',
            'bestaudio[abr<=128][ext=m4a]/bestaudio[abr<=128]/bestaudio/ba/best',
            '--no-playlist',
            '--force-ipv4',
            '--no-warnings',
            url,
          ],
        ).timeout(const Duration(seconds: 7));
        if (res.exitCode == 0) {
          final out = res.stdout.toString().trim();
          final lines = out.split(RegExp(r'[\r\n]+')).map((l) => l.trim()).where((l) => l.startsWith('http')).toList();
          if (lines.isNotEmpty) {
            final streamUrl = lines.first;
            _streamUrlMemoryCache[videoId] = _CachedStreamUrl(
              streamUrl,
              DateTime.now().add(const Duration(hours: 4)),
            );
            return streamUrl;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  /// Clean up resources on shutdown.
  static void dispose() {}
}

class _CachedStreamUrl {
  final String url;
  final DateTime expiresAt;

  const _CachedStreamUrl(this.url, this.expiresAt);
}
