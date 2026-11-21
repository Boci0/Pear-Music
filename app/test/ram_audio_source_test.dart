import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/services/backup_audio_engine.dart';
import 'package:peerm_app/services/innertube_audio_engine.dart';
import 'package:peerm_app/services/ram_audio_source.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

Map<String, dynamic> _playerOk({int size = 120000}) => {
      'playabilityStatus': {'status': 'OK'},
      'responseContext': {'visitorData': 'ram-test-visitor'},
      'streamingData': {
        'adaptiveFormats': [
          {
            'itag': 251,
            'mimeType': 'audio/webm; codecs="opus"',
            'averageBitrate': 128000,
            'contentLength': '$size',
            'url': 'https://ramtest.invalid/251',
          },
        ],
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Directory.systemTemp.createTempSync('peerm_ram_audio_');

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => sandbox.path);
  });

  tearDownAll(() {
    try {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    StreamCacheManager.debugAllowFastEngineInTests = false;
    StreamCacheManager.debugSkipFallbackEngines = true;
    StreamCacheManager.clearRamCacheForTesting();
    InnerTubeAudioEngine.debugReset();
    BackupAudioEngine.debugLoadOverride = null;
    BackupAudioEngine.debugOpenOverride = null;
  });

  tearDown(() async {
    StreamCacheManager.debugAllowFastEngineInTests = false;
    StreamCacheManager.debugSkipFallbackEngines = false;
    StreamCacheManager.cancelActiveDownload();
    StreamCacheManager.cancelPreload();
    await StreamCacheManager.clearCache();
    InnerTubeAudioEngine.debugReset();
    BackupAudioEngine.debugLoadOverride = null;
    BackupAudioEngine.debugOpenOverride = null;
  });

  group('RamAudioBuffer & RamAudioSource', () {
    test('reads growing buffer concurrently and closes cleanly at EOF', () async {
      final buf = RamAudioBuffer(
        videoId: 'grow1',
        ext: 'webm',
        expectedLength: 6,
      );
      final src = RamAudioSource(
        buffer: buf,
        contentType: 'audio/webm',
        stallTimeout: const Duration(seconds: 2),
      );

      final res = await src.request();
      expect(res.rangeRequestsSupported, isTrue);
      expect(res.sourceLength, 6);
      expect(res.contentLength, 6);
      expect(res.offset, isNull);

      final received = <int>[];
      final done = res.stream.forEach(received.addAll);

      final chunk = [1, 2, 3];
      buf.append(chunk);
      // Mutating caller list after append must not corrupt buffered audio.
      chunk[0] = 99;

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, [1, 2, 3]);

      buf.append([4, 5, 6]);
      buf.markComplete();
      await done.timeout(const Duration(seconds: 2));
      expect(received, [1, 2, 3, 4, 5, 6]);
      expect(buf.toBytes(), [1, 2, 3, 4, 5, 6]);
      src.close();
    });

    test('range requests clamp past total and handle null expectedLength safely',
        () async {
      final sized = RamAudioBuffer(
        videoId: 'rng1',
        ext: 'webm',
        expectedLength: 10,
      )..append(List.generate(10, (i) => i))
        ..markComplete();
      final sizedSrc = RamAudioSource(buffer: sized);
      final r1 = await sizedSrc.request(4, 999);
      expect(r1.rangeRequestsSupported, isTrue);
      expect(r1.sourceLength, 10);
      expect(r1.offset, 4);
      expect(r1.contentLength, 6);
      expect(await r1.stream.expand((b) => b).toList(), [4, 5, 6, 7, 8, 9]);

      final unsized = RamAudioBuffer(videoId: 'unsized1', ext: 'm4a')
        ..append([7, 8]);
      final unsizedSrc = RamAudioSource(buffer: unsized);
      final r2 = await unsizedSrc.request(0, null);
      // Offset must stay null when contentLength is null so just_audio proxy
      // never force-unwraps a null contentLength.
      expect(r2.rangeRequestsSupported, isFalse);
      expect(r2.contentLength, isNull);
      expect(r2.offset, isNull);
      unsized.markComplete();
      expect(await r2.stream.expand((b) => b).toList(), [7, 8]);
    });

    test('markFailed propagates error to active readers and new requests',
        () async {
      final buf = RamAudioBuffer(
        videoId: 'fail1',
        ext: 'webm',
        expectedLength: 100,
      )..append([1, 2, 3]);
      final src = RamAudioSource(buffer: buf);

      final res = await src.request(0, 100);
      final chunks = <List<int>>[];
      final err = Completer<Object>();
      res.stream.listen(
        chunks.add,
        onError: (Object e) {
          if (!err.isCompleted) err.complete(e);
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      buf.markFailed('http 403');
      expect(await err.future.timeout(const Duration(seconds: 2)), isA<StateError>());
      await expectLater(src.request(0, 50), throwsA(isA<StateError>()));
    });

    test('stall timeout errors and close() blocks further requests', () async {
      final buf = RamAudioBuffer(
        videoId: 'stall1',
        ext: 'webm',
        expectedLength: 100,
      );
      final src = RamAudioSource(
        buffer: buf,
        stallTimeout: const Duration(milliseconds: 60),
      );
      final res = await src.request();
      await expectLater(
        res.stream.toList(),
        throwsA(isA<StateError>()),
      );
      src.close();
      await expectLater(src.request(), throwsA(isA<StateError>()));
    });
  });

  group('BackupAudioEngine RAM vs disk modes', () {
    late Directory dir;
    const candidate = BackupAudioCandidate(
      container: 'webm',
      codec: 'opus',
      kbps: 128,
      bytes: 120000,
    );

    setUp(() {
      dir = Directory.systemTemp.createTempSync('peerm_ram_backup_');
      BackupAudioEngine.debugLoadOverride = (_) async => [candidate];
      BackupAudioEngine.debugOpenOverride =
          (_) => Stream.value(List.filled(120000, 9));
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('writeToDisk: false buffers in RAM with zero disk writes', () async {
      final result = await BackupAudioEngine.fetch(
        'ramvid1',
        dir: dir,
        preferAac: false,
        writeToDisk: false,
        shouldAbort: () => false,
      );
      expect(result.isOk, isTrue);
      expect(result.file, isNull);
      expect(result.buffer, isNotNull);
      expect(result.buffer!.isComplete, isTrue);
      expect(result.buffer!.length, 120000);
      expect(dir.listSync(), isEmpty);
    });

    test('writeToDisk: true writes once atomically without .tmp. scrap',
        () async {
      final result = await BackupAudioEngine.fetch(
        'diskvid1',
        dir: dir,
        preferAac: false,
        writeToDisk: true,
        shouldAbort: () => false,
      );
      expect(result.isOk, isTrue);
      expect(result.buffer, isNull);
      expect(result.file, isNotNull);
      expect(result.file!.lengthSync(), 120000);
      final files = dir.listSync().map((e) => p.basename(e.path)).toList();
      expect(files, ['diskvid1.webm']);
    });
  });

  group('StreamCacheManager RAM cache, LRU eviction & atomic flush', () {
    test('RAM cache hit, LRU eviction by track count, flushRamToDisk & clearCache',
        () async {
      StreamCacheManager.debugAllowFastEngineInTests = true;
      InnerTubeAudioEngine.debugPlayerOverride =
          (_, _) async => _playerOk(size: 80000);
      InnerTubeAudioEngine.debugOpenOverride =
          (url, bytes) => Stream.value(List.filled(bytes, 4));

      // Clear disk cache folder first so we can verify zero disk writes.
      await StreamCacheManager.clearCache();
      final dir = await StreamCacheManager.getCacheDirectory();

      // Fill maxRamCacheTracks + 1 tracks (4 + 1 = 5). Touch 'ram_0' via
      // getRamCachedBuffer before adding 'ram_4' so 'ram_1' becomes the LRU victim.
      for (var i = 0; i < StreamCacheManager.maxRamCacheTracks; i++) {
        await StreamCacheManager.ensureStreamCached('ram_$i', isPreload: true);
      }
      expect(dir.listSync().whereType<File>(), isEmpty);

      // Touch ram_0 so ram_1 is oldest.
      expect(StreamCacheManager.getRamCachedBuffer('ram_0'), isNotNull);
      expect(StreamCacheManager.isStreamCachedSync('ram_0'), isTrue);

      await StreamCacheManager.ensureStreamCached('ram_4', isPreload: true);
      expect(StreamCacheManager.getRamCachedBuffer('ram_1'), isNull);
      expect(StreamCacheManager.getRamCachedBuffer('ram_0'), isNotNull);
      expect(StreamCacheManager.getRamCachedBuffer('ram_4'), isNotNull);
      expect(dir.listSync().whereType<File>(), isEmpty);

      // Flush ram_0 to disk once and confirm RAM entry is released.
      final flushed = await StreamCacheManager.flushRamToDisk('ram_0');
      expect(flushed, isNotNull);
      expect(flushed!.existsSync(), isTrue);
      expect(flushed.lengthSync(), 80000);
      expect(StreamCacheManager.getRamCachedBuffer('ram_0'), isNull);
      expect(await StreamCacheManager.getCachedFile('ram_0'), isNotNull);

      // clearCache clears both disk and remaining RAM buffers.
      await StreamCacheManager.clearCache();
      expect(StreamCacheManager.getRamCachedBuffer('ram_4'), isNull);
      expect(StreamCacheManager.isStreamCachedSync('ram_4'), isFalse);
      expect(StreamCacheManager.isStreamCachedSync('ram_0'), isFalse);
    });

    test('evicts LRU entries when total RAM exceeds maxRamCacheBytes', () async {
      StreamCacheManager.debugAllowFastEngineInTests = true;
      const trackSize = 12 * 1024 * 1024; // 12 MB each -> 3 tracks = 36 MB > 32 MB
      InnerTubeAudioEngine.debugPlayerOverride =
          (_, _) async => _playerOk(size: trackSize);
      InnerTubeAudioEngine.debugOpenOverride =
          (url, bytes) => Stream.value(List.filled(bytes, 1));

      await StreamCacheManager.ensureStreamCached('big_0', isPreload: true);
      await StreamCacheManager.ensureStreamCached('big_1', isPreload: true);
      expect(StreamCacheManager.getRamCachedBuffer('big_0'), isNotNull);
      expect(StreamCacheManager.getRamCachedBuffer('big_1'), isNotNull);

      await StreamCacheManager.ensureStreamCached('big_2', isPreload: true);
      // 36 MB > 32 MB cap -> big_0 evicted even though track count is 3 <= 4.
      expect(StreamCacheManager.getRamCachedBuffer('big_0'), isNull);
      expect(StreamCacheManager.getRamCachedBuffer('big_1'), isNotNull);
      expect(StreamCacheManager.getRamCachedBuffer('big_2'), isNotNull);
    });
  });
}
