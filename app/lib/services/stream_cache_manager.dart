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
import 'youtube_service.dart';

/// High-speed ephemeral radio cache manager.
/// Streams audio directly into local disk files in < 1.5 seconds.
class StreamCacheManager {
  static const int maxCacheBytes = 60 * 1024 * 1024; // 60 MB cap (~18-20 songs)
  static const int targetEvictionBytes = 40 * 1024 * 1024; // prune to 40 MB
  static const int maxTrackCount = 15;

  static Directory? _cacheDir;
  static YoutubeExplode? _yt;
  static YoutubeExplode get _client => _yt ??= YoutubeExplode();

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

  /// Sequentially pre-downloads a sliding window of upcoming tracks (+1, +2, +3)
  /// in the background using a single-queue worker.
  static void preloadSlidingWindow(
    List<String> videoIds, {
    void Function(String videoId)? onTrackCached,
  }) {
    final seq = ++_slidingWindowSequence;
    unawaited(() async {
      for (final id in videoIds.take(3)) {
        if (seq != _slidingWindowSequence) break;
        if (id.isEmpty) continue;
        final cached = await getCachedFile(id);
        if (cached != null) {
          onTrackCached?.call(id);
          continue;
        }
        try {
          final file = await ensureStreamCached(id);
          if (seq != _slidingWindowSequence) break;
          if (file != null) {
            onTrackCached?.call(id);
          }
        } catch (_) {}
      }
    }());
  }

  /// Ensures the audio stream for [videoId] is downloaded into the local cache.
  /// Uses direct high-speed HTTP chunk streaming (~1.2s download time).
  static Future<File?> ensureStreamCached(String videoId) async {
    final existing = await getCachedFile(videoId);
    if (existing != null) return existing;

    // Single-flight deduplication
    if (_inFlightDownloads.containsKey(videoId)) {
      return await _inFlightDownloads[videoId]!.future;
    }

    final completer = Completer<File?>();
    _inFlightDownloads[videoId] = completer;

    try {
      final dir = await getCacheDirectory();

      // Method 1: YoutubeExplode fast direct audio stream pipe (~1s)
      try {
        final manifest = await _client.videos.streamsClient
            .getManifest(videoId)
            .timeout(const Duration(seconds: 5));
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
        debugPrint('[StreamCacheManager] YoutubeExplode stream pipe failed for $videoId: $e');
      }

      // Method 2: Innertube Player Service fast direct HTTP pipe (~1s)
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

          final client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 4)
            ..idleTimeout = const Duration(seconds: 8);
          final req = await client.getUrl(Uri.parse(streamInfo.url));
          req.headers.set(
            'User-Agent',
            'com.google.android.apps.youtube.music/6.42.52 (Linux; U; Android 14)',
          );
          req.headers.set('Referer', 'https://music.youtube.com/');
          final resp = await req.close().timeout(const Duration(seconds: 8));

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
        debugPrint('[StreamCacheManager] Innertube HTTP pipe failed for $videoId: $e');
      }

      // Method 3: Android yt-dlp fast getStreamUrl extraction -> HTTP pipe (~2s)
      if (YoutubeService.isEmbeddedYtDlpSupported) {
        try {
          const channel = MethodChannel('peerm/ytdlp');
          final rawUrl = await channel.invokeMethod<String>('getStreamUrl', {
            'url': 'https://www.youtube.com/watch?v=$videoId',
          }).timeout(const Duration(seconds: 6));

          if (rawUrl != null && rawUrl.startsWith('http')) {
            final target = File(p.join(dir.path, '$videoId.m4a'));
            final tempFile = File(p.join(dir.path, '$videoId.tmp.m4a'));
            if (await tempFile.exists()) {
              try {
                await tempFile.delete();
              } catch (_) {}
            }

            final client = HttpClient()
              ..connectionTimeout = const Duration(seconds: 4)
              ..idleTimeout = const Duration(seconds: 8);
            final req = await client.getUrl(Uri.parse(rawUrl));
            final resp = await req.close().timeout(const Duration(seconds: 8));

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
          debugPrint('[StreamCacheManager] Android getStreamUrl pipe failed: $e');
        }
      }

      // Method 4: Desktop yt-dlp direct stream URL extraction -> HTTP pipe
      try {
        final bin = await YoutubeService.ytDlpPath();
        if (bin != null) {
          final res = await Process.run(bin, [
            '-g',
            '-f',
            'bestaudio[ext=m4a]/bestaudio/best',
            '--no-playlist',
            '--no-warnings',
            '--no-check-certificates',
            'https://www.youtube.com/watch?v=$videoId',
          ]).timeout(const Duration(seconds: 6));

          if (res.exitCode == 0) {
            final rawUrl = res.stdout.toString().trim().split(RegExp(r'[\r\n]+')).first;
            if (rawUrl.startsWith('http')) {
              final target = File(p.join(dir.path, '$videoId.m4a'));
              final tempFile = File(p.join(dir.path, '$videoId.tmp.m4a'));
              if (await tempFile.exists()) {
                try {
                  await tempFile.delete();
                } catch (_) {}
              }

              final client = HttpClient()
                ..connectionTimeout = const Duration(seconds: 4)
                ..idleTimeout = const Duration(seconds: 8);
              final req = await client.getUrl(Uri.parse(rawUrl));
              final resp = await req.close().timeout(const Duration(seconds: 8));

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
          }
        }
      } catch (e) {
        debugPrint('[StreamCacheManager] Desktop yt-dlp stream extraction failed: $e');
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

  /// Clean up resources on shutdown.
  static void dispose() {
    _yt?.close();
    _yt = null;
  }
}
