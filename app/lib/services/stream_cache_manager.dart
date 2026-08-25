import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/song.dart';
import 'library_service.dart';
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

  static final Map<String, String> _streamUrlCache = {};

  /// Resolves the best audio-only stream URI for a given [videoId].
  static Future<Uri?> resolveStreamUri(String videoId) async {
    if (_streamUrlCache.containsKey(videoId)) {
      return Uri.tryParse(_streamUrlCache[videoId]!);
    }

    // Attempt 1: Fast youtube_explode resolution
    try {
      final manifest = await _client.videos.streamsClient
          .getManifest(videoId)
          .timeout(const Duration(seconds: 4));
      final audioOnly = manifest.audioOnly.withHighestBitrate();
      final urlStr = audioOnly.url.toString();
      _streamUrlCache[videoId] = urlStr;
      return audioOnly.url;
    } catch (e) {
      debugPrint('[StreamCacheManager] youtube_explode failed, trying yt-dlp: $e');
    }

    // Attempt 2: yt-dlp -g fallback (reliable on desktop)
    try {
      final bin = await YoutubeService.ytDlpPath();
      if (bin != null) {
        final res = await Process.run(bin, [
          '-g',
          '-f',
          'bestaudio/best',
          'https://www.youtube.com/watch?v=$videoId',
        ]).timeout(const Duration(seconds: 6));
        if (res.exitCode == 0) {
          final line = res.stdout.toString().trim().split(RegExp(r'\r?\n')).first;
          if (line.startsWith('http')) {
            _streamUrlCache[videoId] = line;
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
    try {
      final dir = await getCacheDirectory();
      final targetFile = File(p.join(dir.path, '$videoId.m4a'));
      if (await targetFile.exists() && (await targetFile.length()) > 50000) {
        return targetFile;
      }

      final partFile = File(p.join(dir.path, '$videoId.part'));
      if (await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }

      // Download audio stream cleanly via youtube_explode
      final manifest = await _client.videos.streamsClient
          .getManifest(videoId)
          .timeout(const Duration(seconds: 8));
      final audio = manifest.audioOnly.withHighestBitrate();
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
        unawaited(enforceCacheQuota());
        return targetFile;
      }
    } catch (e) {
      debugPrint('[StreamCacheManager] ensureStreamCached error for $videoId: $e');
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

  /// Trims stream cache directory to remain strictly under the [maxCacheBytes] quota.
  static Future<void> enforceCacheQuota() async {
    try {
      final dir = await getCacheDirectory();
      final entities = await dir.list().toList();
      final files = entities.whereType<File>().toList();
      int totalSize = 0;
      final fileStats = <File, FileStat>{};

      for (final f in files) {
        final stat = await f.stat();
        fileStats[f] = stat;
        totalSize += stat.size;
      }

      if (totalSize <= maxCacheBytes) return;

      // Sort by last accessed / modified (oldest first)
      files.sort((a, b) {
        final statA = fileStats[a]!;
        final statB = fileStats[b]!;
        return statA.modified.compareTo(statB.modified);
      });

      for (final f in files) {
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
  static Future<Song?> saveToLibrary(Song streamSong, LibraryService library) async {
    try {
      final videoId = streamSong.id.replaceFirst('stream_', '');
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
