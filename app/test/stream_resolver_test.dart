import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service/stream_resolver.dart';
import 'package:peerm_app/services/ram_audio_source.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

class _FakeCachePort extends StreamCachePort {
  File? diskHit;
  RamAudioBuffer? ramHit;
  RamAudioBuffer? ramAfter;
  bool knownLive = false;
  bool evicted = false;
  StreamFetchFailure? failure;
  final List<File?> queuedDownloads = [];
  void Function(void Function(ResolvedStream)?)? onEnsure;

  @override
  void cancelPreload({String? exceptVideoId}) {}

  @override
  void cancelActiveDownload({String? exceptVideoId}) {}

  @override
  Future<File?> getCachedFile(String videoId) async => diskHit;

  @override
  Future<void> markPlayed(File file) async {}

  @override
  RamAudioBuffer? getRamCachedBuffer(String videoId) => ramHit ?? ramAfter;

  @override
  bool isStreamCachedSync(String videoId) => diskHit != null;

  @override
  bool isKnownLive(String videoId) => knownLive;

  @override
  Future<void> evictUnplayable(File file) async {
    evicted = true;
  }

  @override
  Future<File?> ensureStreamCached(
    String videoId, {
    void Function(ResolvedStream stream)? onStreamUrl,
  }) async {
    onEnsure?.call(onStreamUrl);
    if (queuedDownloads.isNotEmpty) {
      return queuedDownloads.removeAt(0);
    }
    return null;
  }

  @override
  StreamFetchFailure? takeFetchFailure(String videoId) => failure;
}

void main() {
  late Directory tempDir;
  late LibraryService library;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('peerm_resolver_test_');
    library = LibraryService()..debugBaseDirectory = tempDir;
    await library.init();
  });

  tearDown(() {
    library.dispose();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Song streamSong([String id = 'abcdefghijk']) => Song(
    id: 'stream_$id',
    title: 'Test Track',
    fileName: 'Test Track [$id].m4a',
    size: 1000,
    checksum: 'stream_$id',
    sourceDeviceId: 'stream',
    addedAt: DateTime(2026),
  );

  test('opens disk cache hit immediately without calling ensureStreamCached', () async {
    final cached = File('${tempDir.path}${Platform.pathSeparator}cached.m4a');
    await cached.writeAsBytes([1, 2, 3, 4]);

    final port = _FakeCachePort()..diskHit = cached;
    final resolver = StreamPlaybackResolver(cache: port);
    final openedSources = <AudioSource>[];
    final metadataEvents = <StreamLoadMetadata>[];
    var markedOpened = false;

    final outcome = await resolver.resolveAndOpen(
      song: streamSong(),
      library: library,
      stopwatch: Stopwatch()..start(),
      earlyStreamOpenTimeout: const Duration(seconds: 5),
      isStale: () => false,
      openSource: (source, {timeout}) async => openedSources.add(source),
      onMetadata: metadataEvents.add,
      onBuffering: ({required buffering, videoId}) {},
      onOpened: () => markedOpened = true,
      tryOpenLive: (_) async => false,
      cachedRouteType: StreamRouteType.cached,
      directRouteType: StreamRouteType.direct,
    );

    expect(outcome, isA<StreamResolutionOpened>());
    expect(markedOpened, isTrue);
    expect(openedSources.length, 1);
    expect(metadataEvents.single.routeType, StreamRouteType.cached);
    expect(metadataEvents.single.loadedFile?.path, cached.path);
  });

  test('evicts unplayable cached file and rethrows on open failure', () async {
    final cached = File('${tempDir.path}${Platform.pathSeparator}bad.m4a');
    await cached.writeAsBytes([1, 2, 3, 4]);

    final port = _FakeCachePort()..diskHit = cached;
    final resolver = StreamPlaybackResolver(cache: port);

    await expectLater(
      () => resolver.resolveAndOpen(
        song: streamSong(),
        library: library,
        stopwatch: Stopwatch()..start(),
        earlyStreamOpenTimeout: const Duration(seconds: 5),
        isStale: () => false,
        openSource: (source, {timeout}) async => throw StateError('bad file'),
        onMetadata: (_) {},
        onBuffering: ({required buffering, videoId}) {},
        onOpened: () {},
        tryOpenLive: (_) async => false,
        cachedRouteType: StreamRouteType.cached,
        directRouteType: StreamRouteType.direct,
      ),
      throwsStateError,
    );
    expect(port.evicted, isTrue);
  });

  test('opens RAM cache hit and returns RamAudioSource in outcome', () async {
    final buf = RamAudioBuffer(
      videoId: 'abcdefghijk',
      ext: 'webm',
      expectedLength: 4,
    )
      ..append([9, 8, 7, 6])
      ..markComplete();
    final port = _FakeCachePort()..ramHit = buf;
    final resolver = StreamPlaybackResolver(cache: port);
    var opened = false;

    final outcome = await resolver.resolveAndOpen(
      song: streamSong(),
      library: library,
      stopwatch: Stopwatch()..start(),
      earlyStreamOpenTimeout: const Duration(seconds: 5),
      isStale: () => false,
      openSource: (source, {timeout}) async {
        expect(source, isA<RamAudioSource>());
      },
      onMetadata: (m) => expect(m.loadedFormat, 'webm'),
      onBuffering: ({required buffering, videoId}) {},
      onOpened: () => opened = true,
      tryOpenLive: (_) async => false,
      cachedRouteType: StreamRouteType.cached,
      directRouteType: StreamRouteType.direct,
    );

    expect(opened, isTrue);
    expect(outcome, isA<StreamResolutionOpened>());
    final ramOutcome = outcome as StreamResolutionOpened;
    expect(ramOutcome.ramSource, isNotNull);
    ramOutcome.ramSource?.close();
  });

  test('retries once on null fetch and opens second attempt download', () async {
    final downloaded = File('${tempDir.path}${Platform.pathSeparator}dl.m4a');
    await downloaded.writeAsBytes([5, 6, 7, 8]);

    final port = _FakeCachePort()..queuedDownloads.addAll([null, downloaded]);
    final resolver = StreamPlaybackResolver(cache: port);
    final bufferingStates = <bool>[];

    final outcome = await resolver.resolveAndOpen(
      song: streamSong(),
      library: library,
      stopwatch: Stopwatch()..start(),
      earlyStreamOpenTimeout: const Duration(seconds: 5),
      isStale: () => false,
      openSource: (source, {timeout}) async {},
      onMetadata: (_) {},
      onBuffering: ({required buffering, videoId}) =>
          bufferingStates.add(buffering),
      onOpened: () {},
      tryOpenLive: (_) async => false,
      cachedRouteType: StreamRouteType.cached,
      directRouteType: StreamRouteType.direct,
      retryDelay: const Duration(milliseconds: 10),
    );

    expect(outcome, isA<StreamResolutionOpened>());
    expect(bufferingStates, [true, false]);
  });

  test('falls back to live stream when isKnownLive is true', () async {
    final port = _FakeCachePort()..knownLive = true;
    final resolver = StreamPlaybackResolver(cache: port);
    var triedLive = false;

    final outcome = await resolver.resolveAndOpen(
      song: streamSong(),
      library: library,
      stopwatch: Stopwatch()..start(),
      earlyStreamOpenTimeout: const Duration(seconds: 5),
      isStale: () => false,
      openSource: (source, {timeout}) async {},
      onMetadata: (_) {},
      onBuffering: ({required buffering, videoId}) {},
      onOpened: () {},
      tryOpenLive: (_) async {
        triedLive = true;
        return true;
      },
      cachedRouteType: StreamRouteType.cached,
      directRouteType: StreamRouteType.direct,
      retryDelay: Duration.zero,
    );

    expect(triedLive, isTrue);
    expect(outcome, isA<StreamResolutionOpened>());
  });

  test('returns StreamResolutionFailed with takeFetchFailure when all paths fail', () async {
    const failure = StreamFetchFailure(
      kind: StreamFetchFailureKind.unavailable,
      detail: 'Video unavailable',
      videoId: 'abcdefghijk',
    );
    final port = _FakeCachePort()..failure = failure;
    final resolver = StreamPlaybackResolver(cache: port);

    final outcome = await resolver.resolveAndOpen(
      song: streamSong(),
      library: library,
      stopwatch: Stopwatch()..start(),
      earlyStreamOpenTimeout: const Duration(seconds: 5),
      isStale: () => false,
      openSource: (source, {timeout}) async {},
      onMetadata: (_) {},
      onBuffering: ({required buffering, videoId}) {},
      onOpened: () {},
      tryOpenLive: (_) async => false,
      cachedRouteType: StreamRouteType.cached,
      directRouteType: StreamRouteType.direct,
      retryDelay: Duration.zero,
    );

    expect(outcome, isA<StreamResolutionFailed>());
    expect((outcome as StreamResolutionFailed).failure, failure);
  });

  test('returns StreamResolutionSuperseded when token turns stale', () async {
    final port = _FakeCachePort();
    final resolver = StreamPlaybackResolver(cache: port);
    var stale = false;
    port.onEnsure = (_) => stale = true;

    final outcome = await resolver.resolveAndOpen(
      song: streamSong(),
      library: library,
      stopwatch: Stopwatch()..start(),
      earlyStreamOpenTimeout: const Duration(seconds: 5),
      isStale: () => stale,
      openSource: (source, {timeout}) async {},
      onMetadata: (_) {},
      onBuffering: ({required buffering, videoId}) {},
      onOpened: () {},
      tryOpenLive: (_) async => false,
      cachedRouteType: StreamRouteType.cached,
      directRouteType: StreamRouteType.direct,
    );

    expect(outcome, isA<StreamResolutionSuperseded>());
  });
}
