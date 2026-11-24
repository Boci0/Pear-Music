import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import '../../models/song.dart';
import '../debug_log.dart';
import '../growing_file_audio_source.dart';
import '../library_service.dart';
import '../ram_audio_source.dart';
import '../recommendation_service.dart';
import '../stream_cache_manager.dart';

/// Route through which the active song is being served.
enum StreamRouteType {
  cached, // Local disk cache (0ms instant)
  direct, // Primary Innertube direct stream
  fallback, // Secondary Piped / yt-dlp fallback
  local, // Local file
}

/// Metadata reported by [StreamPlaybackResolver] once a stream source is ready
/// to open or has started playing.
class StreamLoadMetadata {
  const StreamLoadMetadata({
    required this.routeType,
    required this.elapsedMs,
    this.loadedFile,
    this.loadedFileSize,
    this.loadedFormat,
    this.ramSource,
    this.growingSource,
    this.buffering = false,
    this.bufferingVideoId,
  });

  final StreamRouteType routeType;
  final int elapsedMs;
  final File? loadedFile;
  final int? loadedFileSize;
  final String? loadedFormat;
  final RamAudioSource? ramSource;
  final GrowingFileAudioSource? growingSource;
  final bool buffering;
  final String? bufferingVideoId;
}

/// Outcome of [StreamPlaybackResolver.resolveAndOpen].
sealed class StreamResolutionOutcome {
  const StreamResolutionOutcome();
}

/// A source was opened successfully in the audio engine.
class StreamResolutionOpened extends StreamResolutionOutcome {
  const StreamResolutionOpened({
    this.pendingDownload,
    this.ramSource,
    this.growingSource,
  });

  final Future<File?>? pendingDownload;
  final RamAudioSource? ramSource;
  final GrowingFileAudioSource? growingSource;
}

/// A newer play request superseded this one before completion.
class StreamResolutionSuperseded extends StreamResolutionOutcome {
  const StreamResolutionSuperseded();
}

/// Resolution failed and no playable source could be opened.
class StreamResolutionFailed extends StreamResolutionOutcome {
  const StreamResolutionFailed({this.failure});

  final StreamFetchFailure? failure;
}

/// Small interface over [StreamCacheManager] so [StreamPlaybackResolver] can be
/// unit-tested without static cache state.
class StreamCachePort {
  const StreamCachePort();

  void cancelPreload({String? exceptVideoId}) =>
      StreamCacheManager.cancelPreload(exceptVideoId: exceptVideoId);

  void cancelActiveDownload({String? exceptVideoId}) =>
      StreamCacheManager.cancelActiveDownload(exceptVideoId: exceptVideoId);

  Future<File?> getCachedFile(String videoId) =>
      StreamCacheManager.getCachedFile(videoId);

  Future<void> markPlayed(File file) => StreamCacheManager.markPlayed(file);

  RamAudioBuffer? getRamCachedBuffer(String videoId) =>
      StreamCacheManager.getRamCachedBuffer(videoId);

  bool isStreamCachedSync(String videoId) =>
      StreamCacheManager.isStreamCachedSync(videoId);

  bool isKnownLive(String videoId) => StreamCacheManager.isKnownLive(videoId);

  Future<void> evictUnplayable(File file) =>
      StreamCacheManager.evictUnplayable(file);

  Future<File?> ensureStreamCached(
    String videoId, {
    void Function(ResolvedStream stream)? onStreamUrl,
  }) => StreamCacheManager.ensureStreamCached(videoId, onStreamUrl: onStreamUrl);

  StreamFetchFailure? takeFetchFailure(String videoId) =>
      StreamCacheManager.takeFetchFailure(videoId);
}

/// Resolves and opens a streamed [Song] (disk cache -> local library copy ->
/// RAM cache -> concurrent stream/download -> single retry -> live fallback).
class StreamPlaybackResolver {
  const StreamPlaybackResolver({this.cache = const StreamCachePort()});

  final StreamCachePort cache;

  /// Resolves [song] and opens its [AudioSource] via [openSource].
  ///
  /// Throws [PlayerInterruptedException] or source-open errors directly when
  /// the engine fails to open a resolved cache/download file so the caller's
  /// unified error handler applies.
  Future<StreamResolutionOutcome> resolveAndOpen({
    required Song song,
    required LibraryService library,
    required Stopwatch stopwatch,
    required Duration earlyStreamOpenTimeout,
    required bool Function() isStale,
    required Future<void> Function(AudioSource source, {Duration? timeout})
    openSource,
    required void Function(StreamLoadMetadata metadata) onMetadata,
    required void Function({required bool buffering, String? videoId})
    onBuffering,
    required void Function() onOpened,
    required Future<bool> Function(String videoId) tryOpenLive,
    required StreamRouteType cachedRouteType,
    required StreamRouteType directRouteType,
    Duration retryDelay = const Duration(milliseconds: 500),
  }) async {
    final videoId =
        RecommendationService.extractVideoId(song.id) ??
        song.id.replaceFirst('stream_', '');
    DebugLog.write(
      '[player] Stream path: checking active preload for $videoId',
    );
    cache.cancelPreload(exceptVideoId: videoId);
    cache.cancelActiveDownload(exceptVideoId: videoId);
    DebugLog.write(
      '[player] Resolved videoId=$videoId, checking disk cache...',
    );

    File? cachedFile = await cache.getCachedFile(videoId);
    if (cachedFile != null) unawaited(cache.markPlayed(cachedFile));
    if (cachedFile == null) {
      for (final s in library.songs) {
        if ((RecommendationService.extractVideoId(s.fileName) == videoId ||
                RecommendationService.extractVideoId(s.id) == videoId) &&
            library.hasSongFile(s)) {
          final file = library.songFile(s);
          if (await file.exists()) {
            cachedFile = file;
            DebugLog.write(
              '[player] Found local library audio for $videoId: ${file.path}',
            );
            break;
          }
        }
      }
    }
    if (isStale()) return const StreamResolutionSuperseded();

    final ramBuf = cachedFile == null
        ? cache.getRamCachedBuffer(videoId)
        : null;

    if (cachedFile != null && await cachedFile.exists()) {
      onMetadata(
        StreamLoadMetadata(
          routeType: cachedRouteType,
          elapsedMs: stopwatch.elapsedMilliseconds,
          loadedFile: cachedFile,
          loadedFileSize: await cachedFile.length(),
          loadedFormat: p.extension(cachedFile.path).replaceFirst('.', ''),
        ),
      );
      DebugLog.write(
        '[player] DISK CACHE HIT (${stopwatch.elapsedMilliseconds}ms): '
        '"${song.title}" [$videoId] file=${cachedFile.path}',
      );
      try {
        await openSource(AudioSource.file(cachedFile.path));
        onOpened();
        return const StreamResolutionOpened();
      } on PlayerInterruptedException {
        DebugLog.write(
          '[player] Cached file load was superseded; keeping it in the cache',
        );
        rethrow;
      } catch (e) {
        DebugLog.write(
          '[player] Cached file unplayable or corrupt: $e. Evicting from cache.',
        );
        await cache.evictUnplayable(cachedFile);
        rethrow;
      }
    }

    if (ramBuf != null) {
      final ramSource = RamAudioSource(
        buffer: ramBuf,
        contentType: ramBuf.ext == 'webm' ? 'audio/webm' : 'audio/mp4',
      );
      onMetadata(
        StreamLoadMetadata(
          routeType: cachedRouteType,
          elapsedMs: stopwatch.elapsedMilliseconds,
          loadedFile: null,
          loadedFileSize: ramBuf.length,
          loadedFormat: ramBuf.ext,
          ramSource: ramSource,
        ),
      );
      DebugLog.write(
        '[player] RAM CACHE HIT (${stopwatch.elapsedMilliseconds}ms): '
        '"${song.title}" [$videoId] (${(ramBuf.length / 1024).round()} KB)',
      );
      try {
        await openSource(ramSource);
        onOpened();
        return StreamResolutionOpened(ramSource: ramSource);
      } catch (e) {
        ramSource.close();
        rethrow;
      }
    }

    onBuffering(buffering: true, videoId: videoId);
    DebugLog.write(
      '[player] DISK CACHE MISS for $videoId, downloading via ensureStreamCached...',
    );

    final linkReady = Completer<ResolvedStream?>();
    final download = cache.ensureStreamCached(
      videoId,
      onStreamUrl: (stream) {
        if (!linkReady.isCompleted) linkReady.complete(stream);
      },
    );
    unawaited(
      download.then(
        (_) {
          if (!linkReady.isCompleted) linkReady.complete(null);
        },
        onError: (_) {
          if (!linkReady.isCompleted) linkReady.complete(null);
        },
      ),
    );
    final link = await linkReady.future;
    if (isStale()) return const StreamResolutionSuperseded();

    var streaming = false;
    RamAudioSource? openedRam;
    GrowingFileAudioSource? openedGrowing;

    if (link != null) {
      final ramBuffer = link.ramBuffer;
      final ramSource = ramBuffer == null
          ? null
          : RamAudioSource(
              buffer: ramBuffer,
              contentType: link.ext == 'webm' ? 'audio/webm' : 'audio/mp4',
            );
      final localPath = link.localPath;
      final growing = (ramSource != null || localPath == null)
          ? null
          : GrowingFileAudioSource(
              path: localPath,
              done: download.then((_) {}, onError: (_) {}),
              expectedLength: link.filesize,
              contentType: link.ext == 'webm' ? 'audio/webm' : 'audio/mp4',
            );
      try {
        final opening = openSource(
          ramSource ??
              growing ??
              AudioSource.uri(Uri.parse(link.url), headers: link.headers),
          timeout: earlyStreamOpenTimeout,
        );
        unawaited(opening.catchError((Object _) {}));

        final fetchEndedEmpty = Completer<void>();
        unawaited(
          download.then(
            (file) {
              final ramReady =
                  (ramBuffer?.isComplete ?? false) ||
                  cache.isStreamCachedSync(videoId);
              if (file == null && !ramReady && !fetchEndedEmpty.isCompleted) {
                fetchEndedEmpty.complete();
              }
            },
            onError: (_) {
              if (!fetchEndedEmpty.isCompleted) fetchEndedEmpty.complete();
            },
          ),
        );
        await Future.any<void>([
          opening,
          fetchEndedEmpty.future.then(
            (_) => throw StateError('the fetch ended without a file'),
          ),
        ]);
        if (isStale()) {
          if (growing != null) unawaited(growing.close());
          ramSource?.close();
          return const StreamResolutionSuperseded();
        }
        openedGrowing = growing;
        openedRam = ramSource;
        onMetadata(
          StreamLoadMetadata(
            routeType: directRouteType,
            elapsedMs: stopwatch.elapsedMilliseconds,
            loadedFile: null,
            loadedFileSize:
                ramBuffer?.isComplete == true ? ramBuffer!.length : null,
            loadedFormat: link.ext,
            ramSource: ramSource,
            growingSource: growing,
          ),
        );
        onOpened();
        streaming = true;
        DebugLog.write(
          '[player] STREAMING while caching (${stopwatch.elapsedMilliseconds}ms): '
          '"${song.title}" [$videoId]',
        );
        unawaited(download.catchError((_) => null));
      } catch (e) {
        if (growing != null) unawaited(growing.close());
        ramSource?.close();
        if (e is PlayerInterruptedException) rethrow;
        if (isStale()) return const StreamResolutionSuperseded();
        DebugLog.write(
          '[player] Early stream would not play ($e); waiting for the cached file instead',
        );
      }
    }

    if (streaming) {
      return StreamResolutionOpened(
        pendingDownload: download,
        ramSource: openedRam,
        growingSource: openedGrowing,
      );
    }

    File? downloadedFile = await download;
    var ramAfter = downloadedFile != null
        ? null
        : cache.getRamCachedBuffer(videoId);

    if (downloadedFile == null &&
        ramAfter == null &&
        !cache.isKnownLive(videoId) &&
        !isStale()) {
      DebugLog.write(
        '[player] Initial stream fetch for $videoId returned null, retrying once...',
      );
      await Future.delayed(retryDelay);
      if (isStale()) return const StreamResolutionSuperseded();
      downloadedFile = await cache.ensureStreamCached(videoId);
      if (downloadedFile == null) {
        ramAfter = cache.getRamCachedBuffer(videoId);
      }
    }

    onBuffering(buffering: false, videoId: null);
    if (isStale()) {
      DebugLog.write('[player] Token stale after download, aborting');
      return const StreamResolutionSuperseded();
    }

    if (downloadedFile != null && await downloadedFile.exists()) {
      final len = await downloadedFile.length();
      onMetadata(
        StreamLoadMetadata(
          routeType: directRouteType,
          elapsedMs: stopwatch.elapsedMilliseconds,
          loadedFile: downloadedFile,
          loadedFileSize: len,
          loadedFormat: p.extension(downloadedFile.path).replaceFirst('.', ''),
        ),
      );
      DebugLog.write(
        '[player] DOWNLOADED OK (${stopwatch.elapsedMilliseconds}ms): '
        '"${song.title}" [$videoId] file=${downloadedFile.path} size=$len bytes',
      );
      try {
        await openSource(AudioSource.file(downloadedFile.path));
        onOpened();
        return StreamResolutionOpened(pendingDownload: download);
      } on PlayerInterruptedException {
        DebugLog.write(
          '[player] Downloaded file load was superseded; keeping it in the cache',
        );
        rethrow;
      } catch (e) {
        DebugLog.write(
          '[player] Downloaded stream unplayable or corrupt: $e. Evicting file.',
        );
        await cache.evictUnplayable(downloadedFile);
        rethrow;
      }
    }

    if (ramAfter != null) {
      final ramSource = RamAudioSource(
        buffer: ramAfter,
        contentType: ramAfter.ext == 'webm' ? 'audio/webm' : 'audio/mp4',
      );
      onMetadata(
        StreamLoadMetadata(
          routeType: directRouteType,
          elapsedMs: stopwatch.elapsedMilliseconds,
          loadedFile: null,
          loadedFileSize: ramAfter.length,
          loadedFormat: ramAfter.ext,
          ramSource: ramSource,
        ),
      );
      DebugLog.write(
        '[player] BUFFERED IN RAM OK (${stopwatch.elapsedMilliseconds}ms): '
        '"${song.title}" [$videoId] size=${ramAfter.length} bytes',
      );
      try {
        await openSource(ramSource);
        onOpened();
        return StreamResolutionOpened(
          pendingDownload: download,
          ramSource: ramSource,
        );
      } catch (e) {
        ramSource.close();
        rethrow;
      }
    }

    if (cache.isKnownLive(videoId) && await tryOpenLive(videoId)) {
      if (isStale()) return const StreamResolutionSuperseded();
      onOpened();
      return StreamResolutionOpened(pendingDownload: download);
    }

    return StreamResolutionFailed(failure: cache.takeFetchFailure(videoId));
  }
}
