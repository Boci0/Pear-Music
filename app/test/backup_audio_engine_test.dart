import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/services/backup_audio_engine.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

BackupAudioCandidate _c(String container, String codec, double kbps,
        {int bytes = 100000}) =>
    BackupAudioCandidate(
      container: container,
      codec: codec,
      kbps: kbps,
      bytes: bytes,
    );

void main() {
  group('BackupAudioEngine.pickStream', () {
    // What the engine reports for a typical music video.
    final typical = [
      _c('webm', 'opus', 133),
      _c('mp4', 'mp4a.40.2', 128),
      _c('mp4', 'mp4a.40.5', 49),
      _c('webm', 'opus', 48),
    ];

    test('desktop takes the best Opus under the cap', () {
      final pick = BackupAudioEngine.pickStream(typical, preferAac: false)!;
      expect(pick.codec, 'opus');
      expect(pick.kbps, 133);
    });

    test('the phone takes AAC under the cap first', () {
      final pick = BackupAudioEngine.pickStream(typical, preferAac: true)!;
      expect(pick.codec, 'mp4a.40.2');
    });

    test('a stream over the cap is only used when nothing else is left', () {
      final loud = [_c('webm', 'opus', 256), _c('webm', 'opus', 160)];
      expect(
        BackupAudioEngine.pickStream(loud, preferAac: false)!.kbps,
        256,
        reason: 'no Opus under the cap, so the best Opus wins',
      );
      final mixed = [_c('webm', 'opus', 256), _c('mp4', 'mp4a.40.2', 128)];
      expect(
        BackupAudioEngine.pickStream(mixed, preferAac: false)!.codec,
        'opus',
        reason: 'any Opus beats AAC on desktop',
      );
    });

    test('an empty list picks nothing and an unknown codec still gets picked', () {
      expect(BackupAudioEngine.pickStream(const [], preferAac: false), isNull);
      expect(
        BackupAudioEngine.pickStream([_c('webm', 'vorbis', 96)], preferAac: false)!
            .codec,
        'vorbis',
      );
    });

    test('containers map to the extensions the cache looks for', () {
      expect(BackupAudioEngine.extensionFor('webm'), 'webm');
      expect(BackupAudioEngine.extensionFor('mp4'), 'm4a');
    });
  });

  group('BackupAudioEngine.fetch', () {
    late Directory dir;
    final candidate = _c('webm', 'opus', 128, bytes: 120000);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('pm_backup_test_');
      BackupAudioEngine.debugLoadOverride = (_) async => [candidate];
    });
    tearDown(() {
      BackupAudioEngine.debugLoadOverride = null;
      BackupAudioEngine.debugOpenOverride = null;
      dir.deleteSync(recursive: true);
    });

    Stream<List<int>> bytes(int total, {int chunk = 20000}) async* {
      var left = total;
      while (left > 0) {
        final n = left < chunk ? left : chunk;
        left -= n;
        yield List.filled(n, 7);
      }
    }

    Future<BackupFetchResult> run({
      bool Function()? abort,
      Duration idle = const Duration(milliseconds: 300),
    }) =>
        BackupAudioEngine.fetch(
          'vid12345678',
          dir: dir,
          preferAac: false,
          shouldAbort: abort ?? () => false,
          idleTimeout: idle,
        );

    List<String> names() =>
        dir.listSync().map((e) => p.basename(e.path)).toList()..sort();

    test('a complete download lands as <id>.<ext> with no scrap left behind', () async {
      BackupAudioEngine.debugOpenOverride = (_) => bytes(120000);
      final r = await run();
      expect(r.error, isNull);
      expect(r.file!.lengthSync(), 120000);
      expect(names(), ['vid12345678.webm']);
    });

    test('a short download is rejected and removed', () async {
      BackupAudioEngine.debugOpenOverride = (_) => bytes(60000);
      final r = await run();
      expect(r.file, isNull);
      expect(r.error, contains('incomplete'));
      expect(names(), isEmpty);
    });

    test('a stalled stream gives up after the idle timeout, even if it never ends', () async {
      final never = StreamController<List<int>>();
      // Even a stream that hangs while being cancelled must not hold us up.
      never.onCancel = () => Completer<void>().future;
      BackupAudioEngine.debugOpenOverride = (_) {
        never.add(List.filled(20000, 1));
        return never.stream;
      };
      final sw = Stopwatch()..start();
      final r = await run(idle: const Duration(milliseconds: 250));
      expect(r.file, isNull);
      expect(r.error, contains('stalled'));
      expect(sw.elapsedMilliseconds, lessThan(3000));
      expect(names(), isEmpty);
    });

    test('a cancelled play stops the transfer and leaves nothing behind', () async {
      BackupAudioEngine.debugOpenOverride = (_) => bytes(120000, chunk: 10000);
      var polls = 0;
      final r = await run(abort: () => ++polls > 2);
      expect(r.file, isNull);
      expect(r.error, 'cancelled');
      expect(names(), isEmpty);
    });

    test('a lookup that fails or finds nothing is reported, not thrown', () async {
      BackupAudioEngine.debugLoadOverride = (_) async => const [];
      expect((await run()).error, contains('no audio streams'));
      BackupAudioEngine.debugLoadOverride = (_) async => throw StateError('boom');
      expect((await run()).error, contains('boom'));
    });
  });

  group('when the backup engine is tried', () {
    test('a gone video or a dead network is not retried, the rest is', () {
      for (final kind in StreamFetchFailureKind.values) {
        final retry = StreamCacheManager.backupEngineShouldRetry(kind);
        final expected = kind != StreamFetchFailureKind.unavailable &&
            kind != StreamFetchFailureKind.network;
        expect(retry, expected, reason: '$kind');
      }
      expect(StreamCacheManager.backupEngineShouldRetry(null), isTrue);
    });
  });
}
