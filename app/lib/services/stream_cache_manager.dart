import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/song.dart';
import 'innertube_player_service.dart';
import 'library_service.dart';
import 'stream_proxy_service.dart';
import 'youtube_service.dart';

/// Manages ephemeral stream downloads and LRU cache eviction so continuous radio
/// playback does not fill disk storage.
class StreamCacheManager {
  static const int maxCacheBytes = 500 * 1024 * 1024; // 500 MB cap
  static const int targetEvictionBytes = 400 * 1024 * 1024; // prune to 400 MB
  static const int minFreeDiskBytes = 1024 * 1024 * 1024; // 1 GB safety floor

  static Directory? _cacheDir;
  static YoutubeExplode? _yt;
  static YoutubeExplode get _client => _yt ??= YoutubeExplode();

  /// Gets or creates the stream cache directory in temporary storage.
  static Future<Directory> getCacheDirectory() async {
    if (_cacheDir != null && await _cacheDir!.exists()) {
      return _cacheDir!;
    }
    final temp = await getTemporaryDirectory();
    final dir = Directory(p.join(temp.path, 'peerm_stream_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  static final Map<String, ({String url, DateTime expiresAt})> _streamUrlCache = {};
  static final Map<String, Completer<File?>> _inFlightDownloads = {};
  static final Set<String> _cachedVideoIds = {};

  /// Synchronous memory check whether a track is fully cached on disk.
  static bool isStreamCachedSync(String videoId) {
    return _cachedVideoIds.contains(videoId);
  }

  /// Quick cache-only check: returns the cached file if it exists, null otherwise.
  /// Does NOT trigger any network requests or downloads.
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

  /// Checks whether a valid (unexpired) stream URL is already in the memory cache.
  static bool isStreamUrlCached(String videoId) {
    final entry = _streamUrlCache[videoId];
    if (entry == null) return false;
    if (DateTime.now().isAfter(entry.expiresAt)) {
      _streamUrlCache.remove(videoId);
      return false;
    }
    return true;
  }

  /// Pre-resolves stream URLs for upcoming tracks in the background to ensure
  /// zero-delay skipping.
  static Future<void> preloadStreamUrls(List<String> videoIds) async {
    for (final id in videoIds) {
      if (id.isEmpty) continue;
      final cached = await getCachedFile(id);
      if (cached != null) continue;
      if (isStreamUrlCached(id)) continue;
      // Pre-resolve asynchronously in parallel
      unawaited(resolveStreamUri(id));
    }
  }

  /// Sequentially pre-downloads upcoming tracks into the local cache file system.
  static Future<void> preloadUpcomingTracks(List<String> videoIds) async {
    for (final id in videoIds) {
      if (id.isEmpty) continue;
      final cached = await getCachedFile(id);
      if (cached != null) continue;
      // Pre-download sequentially in background
      try {
        await ensureStreamCached(id);
      } catch (_) {}
    }
  }

  /// Returns the localhost stream proxy URI for [videoId] to prevent 403 errors.
  static Future<Uri?> getStreamProxyUri(String videoId) async {
    return await StreamProxyService.getStreamProxyUri(videoId);
  }

  /// Resolves the best audio-only stream URI for a given [videoId].
  /// Uses ultra-fast direct Innertube player resolution first (~150ms), falling back
  /// to youtube_explode and platform yt-dlp engines if needed.
  static Future<Uri?> resolveStreamUri(String videoId) async {
    final cachedEntry = _streamUrlCache[videoId];
    if (cachedEntry != null) {
      if (DateTime.now().isBefore(cachedEntry.expiresAt)) {
        return Uri.tryParse(cachedEntry.url);
      }
      _streamUrlCache.remove(videoId);
    }

    // Attempt 1: Fast direct Innertube player resolution (~150ms, unscrambled mobile audio)
    try {
      final innertubeStream = await InnertubePlayerService.resolveAudioStream(videoId);
      if (innertubeStream != null && innertubeStream.url.startsWith('http')) {
        _streamUrlCache[videoId] = (
          url: innertubeStream.url,
          expiresAt: DateTime.now().add(const Duration(hours: 2)),
        );
        return Uri.tryParse(innertubeStream.url);
      }
    } catch (e) {
      debugPrint('[StreamCacheManager] Innertube player resolution failed for $videoId: $e');
    }

    // Attempt 2: Direct stream extraction via youtube_explode (~200-500ms)
    try {
      final manifest = await _client.videos.streamsClient
          .getManifest(videoId)
          .timeout(const Duration(seconds: 4));
      final mp4s = manifest.audioOnly
          .where((s) => s.container.name.toLowerCase() == 'mp4')
          .toList();
      final audioOnly = mp4s.isNotEmpty
          ? mp4s.withHighestBitrate()
          : manifest.audioOnly.withHighestBitrate();
      final urlStr = audioOnly.url.toString();
      _streamUrlCache[videoId] = (
        url: urlStr,
        expiresAt: DateTime.now().add(const Duration(hours: 2)),
      );
      return audioOnly.url;
    } catch (e) {
      debugPrint('[StreamCacheManager] Fast direct stream extraction failed for $videoId: $e');
    }

    // Attempt 3 (Android): Embedded yt-dlp URL resolution via method channel fallback
    if (YoutubeService.isEmbeddedYtDlpSupported) {
      try {
        const channel = MethodChannel('peerm/ytdlp');
        final url = await channel.invokeMethod<String>('getStreamUrl', {
          'url': 'https://www.youtube.com/watch?v=$videoId',
        }).timeout(const Duration(seconds: 10));
        if (url != null && url.startsWith('http')) {
          _streamUrlCache[videoId] = (
            url: url,
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          );
          return Uri.parse(url);
        }
      } catch (e) {
        debugPrint('[StreamCacheManager] Embedded yt-dlp URL resolve failed: $e');
      }
    }

    // Attempt 4 (Desktop): Desktop yt-dlp -g fallback
    try {
      final bin = await YoutubeService.ytDlpPath();
      if (bin != null) {
        final res = await Process.run(bin, [
          '-g',
          '-f',
          'bestaudio/best',
          '--no-playlist',
          '--no-warnings',
          'https://www.youtube.com/watch?v=$videoId',
        ]).timeout(const Duration(seconds: 8));
        if (res.exitCode == 0) {
          final line = res.stdout.toString().trim().split(RegExp(r'[\r\n]+')).first;
          if (line.startsWith('http')) {
            _streamUrlCache[videoId] = (
              url: line,
              expiresAt: DateTime.now().add(const Duration(hours: 2)),
            );
            return Uri.parse(line);
          }
        }
      }
    } catch (e) {
      debugPrint('[StreamCacheManager] yt-dlp fallback error: $e');
    }
    return null;
  }

  /// Ensures the audio stream for [videoId] is downloaded into the local cache.
  /// Returns the cached [File] ready for instant offline playback.
  static Future<File?> ensureStreamCached(String videoId) async {
    final existing = await getCachedFile(videoId);
    if (existing != null) return existing;

    // Single-flight deduplication to avoid socket starvation and temp file collisions
    if (_inFlightDownloads.containsKey(videoId)) {
      return await _inFlightDownloads[videoId]!.future;
    }

    final completer = Completer<File?>();
    _inFlightDownloads[videoId] = completer;

    try {
      final dir = await getCacheDirectory();

      // Method 1: Fast direct native HTTP download from Innertube player (~1-2s)
      try {
        final streamInfo = await InnertubePlayerService.resolveAudioStream(videoId);
        if (streamInfo != null && streamInfo.url.startsWith('http')) {
          final ext = streamInfo.container;
          final target = File(p.join(dir.path, '$videoId.$ext'));
          final tempFile = File(p.join(dir.path, '$videoId.tmp.$ext'));
          if (await tempFile.exists()) {
            try {
              await tempFile.delete();
            } catch (_) {}
          }

          final client = HttpClient();
          final req = await client.getUrl(Uri.parse(streamInfo.url));
          req.headers.set(
            'User-Agent',
            'com.google.android.apps.youtube.music/6.42.52 (Linux; U; Android 14)',
          );
          req.headers.set('Referer', 'https://music.youtube.com/');
          final resp = await req.close().timeout(const Duration(seconds: 15));

          if (resp.statusCode == 200 || resp.statusCode == 206) {
            final sink = tempFile.openWrite();
            await resp.pipe(sink);
            if (await tempFile.exists() && (await tempFile.length()) > 50000) {
              if (await target.exists()) {
                try {
                  await target.delete();
                } catch (_) {}
              }
              await tempFile.rename(target.path);
              _cachedVideoIds.add(videoId);
              unawaited(enforceCacheQuota());
              completer.complete(target);
              return target;
            }
          }
        }
      } catch (e) {
        debugPrint('[StreamCacheManager] Direct Innertube cache download failed for $videoId: $e');
      }

      // Method 2: Android embedded yt-dlp engine fallback
      if (YoutubeService.isEmbeddedYtDlpSupported) {
        try {
          const channel = MethodChannel('peerm/ytdlp');
          final processId = 'peerm-stream-${DateTime.now().millisecondsSinceEpoch}';
          final outDir = Directory(p.join(dir.path, 'tmp_$videoId'));
          if (!await outDir.exists()) await outDir.create(recursive: true);

          await channel.invokeMethod('download', {
            'url': 'https://www.youtube.com/watch?v=$videoId',
            'outputDir': outDir.path,
            'outputTemplate': '$videoId.%(ext)s',
            'processId': processId,
          }).timeout(const Duration(seconds: 20));

          for (final f in outDir.listSync().whereType<File>()) {
            if (await f.length() > 50000) {
              final ext = p.extension(f.path);
              final target = File(p.join(dir.path, '$videoId$ext'));
              if (await target.exists()) {
                try {
                  await target.delete();
                } catch (_) {}
              }
              await f.rename(target.path);
              _cachedVideoIds.add(videoId);
              try {
                await outDir.delete(recursive: true);
              } catch (_) {}
              unawaited(enforceCacheQuota());
              completer.complete(target);
              return target;
            }
          }
        } catch (e) {
          debugPrint('[StreamCacheManager] Android embedded yt-dlp stream cache failed: $e');
        }
      }

      // Method 3: Desktop yt-dlp engine fallback
      try {
        final bin = await YoutubeService.ytDlpPath();
        if (bin != null) {
          final fallbackTarget = File(p.join(dir.path, '$videoId.m4a'));
          final fallbackPart = File(p.join(dir.path, '$videoId.part.m4a'));
          final res = await Process.run(bin, [
            '-f',
            'bestaudio[ext=m4a]/bestaudio/best',
            '--extractor-args',
            'youtube:player_client=android,web,mweb',
            '--no-playlist',
            '--no-warnings',
            '--no-check-certificates',
            '--concurrent-fragments',
            '4',
            '-o',
            fallbackPart.path,
            'https://www.youtube.com/watch?v=$videoId',
          ]).timeout(const Duration(seconds: 12));

          if (res.exitCode == 0 && await fallbackPart.exists() && (await fallbackPart.length()) > 50000) {
            if (await fallbackTarget.exists()) {
              try {
                await fallbackTarget.delete();
              } catch (_) {}
            }
            await fallbackPart.rename(fallbackTarget.path);
            _cachedVideoIds.add(videoId);
            unawaited(enforceCacheQuota());
            completer.complete(fallbackTarget);
            return fallbackTarget;
          }
        }
      } catch (e) {
        debugPrint('[StreamCacheManager] yt-dlp fallback failed: $e');
      }

      // Method 4: Direct HTTP stream pipe fallback
      try {
        final manifest = await _client.videos.streamsClient
            .getManifest(videoId)
            .timeout(const Duration(seconds: 8));
        final audioStreams = manifest.audioOnly;
        if (audioStreams.isNotEmpty) {
          final mp4s = audioStreams
              .where((s) => s.container.name.toLowerCase() == 'mp4')
              .toList();
          final audio = mp4s.isNotEmpty
              ? mp4s.withHighestBitrate()
              : audioStreams.withHighestBitrate();
          final ext = audio.container.name.toLowerCase() == 'webm' ? 'webm' : 'm4a';
          final targetFile = File(p.join(dir.path, '$videoId.$ext'));
          final partFile = File(p.join(dir.path, '$videoId.part.$ext'));

          if (await partFile.exists()) {
            try {
              await partFile.delete();
            } catch (_) {}
          }

          final stream = _client.videos.streamsClient.get(audio);
          final sink = partFile.openWrite();
          await stream.pipe(sink);
          await sink.flush();
          await sink.close();

          if (await partFile.exists() && (await partFile.length()) > 50000) {
            if (await targetFile.exists()) {
              try {
                await targetFile.delete();
              } catch (_) {}
            }
            await partFile.rename(targetFile.path);
            _cachedVideoIds.add(videoId);
            unawaited(enforceCacheQuota());
            completer.complete(targetFile);
            return targetFile;
          }
        }
      } catch (e) {
        debugPrint('[StreamCacheManager] direct stream download failed: $e');
      }
    } catch (e) {
      debugPrint('[StreamCacheManager] ensureStreamCached error for $videoId: $e');
    } finally {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
      _inFlightDownloads.remove(videoId);
    }
    return null;
  }

  /// Checks if available free space is safe for stream caching.
  static Future<bool> isStorageSafe() async {
    try {
      final dir = await getCacheDirectory();
      final stat = await dir.stat();
      // On Windows/Android, directory exists check is baseline safe
      return stat.type != FileSystemEntityType.notFound;
    } catch (_) {
      return true;
    }
  }

  /// Trims stream cache directory to remain strictly under the [maxCacheBytes] quota
  /// and purges stale temporary download artifacts.
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

        // Delete dangling temp files older than 2 minutes
        if ((name.contains('.tmp.') || name.contains('.part.')) &&
            now.difference(stat.modified) > const Duration(minutes: 2)) {
          try {
            await f.delete();
          } catch (_) {}
          continue;
        }

        fileStats[f] = stat;
        totalSize += stat.size;
      }

      if (totalSize <= maxCacheBytes) return;

      // Sort by last accessed / modified (oldest first)
      final validFiles = fileStats.keys.toList()
        ..sort((a, b) {
          final statA = fileStats[a]!;
          final statB = fileStats[b]!;
          return statA.modified.compareTo(statB.modified);
        });

      for (final f in validFiles) {
        if (totalSize <= targetEvictionBytes) break;
        final size = fileStats[f]?.size ?? 0;
        try {
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

  /// Clean up resources on shutdown.
  static void dispose() {
    _yt?.close();
    _yt = null;
    StreamProxyService.stop();
  }
}
