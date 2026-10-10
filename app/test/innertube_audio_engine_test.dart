import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/services/backup_audio_engine.dart';
import 'package:peerm_app/services/innertube_audio_engine.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

/// The shape of a player response from the visionOS client: video and audio
/// formats mixed, audio with direct links, a `bitrate` peak above the
/// `averageBitrate` the engine should compare.
Map<String, dynamic> _ok({int size = 120000}) => {
      'playabilityStatus': {'status': 'OK'},
      'responseContext': {'visitorData': 'visitor-1'},
      'streamingData': {
        'adaptiveFormats': [
          {
            'itag': 137,
            'mimeType': 'video/mp4; codecs="avc1.640020"',
            'bitrate': 320000,
            'contentLength': '5000000',
            'url': 'https://v/137',
          },
          {
            'itag': 251,
            'mimeType': 'audio/webm; codecs="opus"',
            'bitrate': 159948,
            'averageBitrate': 126000,
            'contentLength': '$size',
            'url': 'https://v/251',
          },
          {
            'itag': 140,
            'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
            'bitrate': 131167,
            'averageBitrate': 128000,
            'contentLength': '$size',
            'url': 'https://v/140',
          },
          {
            'itag': 141,
            'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
            'bitrate': 256000,
            'contentLength': '$size',
            // A cipher-only format has no direct link and must be ignored.
            'signatureCipher': 's=abc',
          },
        ],
      },
    };

Map<String, dynamic> _bot() => {
      'playabilityStatus': {
        'status': 'LOGIN_REQUIRED',
        'reason': 'Sign in to confirm you are not a bot',
      },
      'responseContext': {'visitorData': 'visitor-1'},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    InnerTubeAudioEngine.debugReset();
    dir = await Directory.systemTemp.createTemp('innertube_test');
  });

  tearDown(() async {
    InnerTubeAudioEngine.debugReset();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('only direct audio links become candidates, with the average bitrate',
      () async {
    InnerTubeAudioEngine.debugPlayerOverride = (_, _) async => _ok();
    final list = await InnerTubeAudioEngine.lookup('abc');
    expect(list.map((c) => c.container).toSet(), {'webm', 'mp4'});
    expect(list, hasLength(2), reason: 'no video, no cipher-only format');
    final opus = list.firstWhere((c) => c.isOpus);
    expect(opus.kbps, 126);
    expect(BackupAudioEngine.pickStream(list, preferAac: false)!.isOpus, isTrue);
    expect(BackupAudioEngine.pickStream(list, preferAac: true)!.isAac, isTrue);
  });

  test('the first bot check is retried once with the visitor id it returned',
      () async {
    final seen = <String?>[];
    InnerTubeAudioEngine.debugPlayerOverride = (_, visitor) async {
      seen.add(visitor);
      return visitor == null ? _bot() : _ok();
    };
    final list = await InnerTubeAudioEngine.lookup('abc');
    expect(list, isNotEmpty);
    expect(seen, [null, 'visitor-1']);

    // The next lookup already carries it: one call, no bot check.
    seen.clear();
    await InnerTubeAudioEngine.lookup('def');
    expect(seen, ['visitor-1']);
  });

  test('a bot check that survives the visitor id is a systemic failure',
      () async {
    InnerTubeAudioEngine.debugPlayerOverride = (_, _) async => _bot();
    await expectLater(
      InnerTubeAudioEngine.lookup('abc'),
      throwsA(isA<InnerTubeFailure>().having((e) => e.systemic, 'systemic', true)),
    );
  });

  test('a video not offered to this client is not a systemic failure', () async {
    InnerTubeAudioEngine.debugPlayerOverride = (_, _) async => {
          'playabilityStatus': {
            'status': 'UNPLAYABLE',
            'reason': 'This video is not available',
          },
        };
    await expectLater(
      InnerTubeAudioEngine.lookup('abc'),
      throwsA(isA<InnerTubeFailure>().having((e) => e.systemic, 'systemic', false)),
    );
  });

  test('a lone server error is retried once', () async {
    var calls = 0;
    InnerTubeAudioEngine.debugPlayerOverride = (_, _) async {
      if (++calls == 1) throw InnerTubeFailure('player HTTP 503', systemic: true);
      return _ok();
    };
    expect(await InnerTubeAudioEngine.lookup('abc'), isNotEmpty);
    expect(calls, 2);
  });

  group('open', () {
    BackupAudioCandidate stream(int bytes) => BackupAudioCandidate(
          container: 'webm',
          codec: 'opus',
          kbps: 126,
          bytes: bytes,
          handle: 'https://v/251',
        );

    test('an empty answer stops the reader instead of asking again forever',
        () async {
      var calls = 0;
      InnerTubeAudioEngine.debugHttpClient = MockClient((_) async {
        calls++;
        return http.Response.bytes(const [], 206);
      });
      await expectLater(
        InnerTubeAudioEngine.open(stream(9000000), 'abc').toList(),
        throwsA(isA<InnerTubeFailure>()),
      );
      expect(calls, 1);
    });

    test('a server that ignores Range is caught on the second chunk',
        () async {
      var calls = 0;
      InnerTubeAudioEngine.debugHttpClient = MockClient((req) async {
        calls++;
        // Asked for 5 MB ranges of a 7 MB file; always answers 200, whole file.
        return http.Response.bytes(List.filled(5 * 1024 * 1024, 1), 200);
      });
      await expectLater(
        InnerTubeAudioEngine.open(stream(7 * 1024 * 1024), 'abc').toList(),
        throwsA(isA<InnerTubeFailure>()
            .having((e) => e.message, 'message', contains('range ignored'))),
      );
      expect(calls, 2);
    });

    test('ranges are requested in order and joined', () async {
      final asked = <String>[];
      InnerTubeAudioEngine.debugHttpClient = MockClient((req) async {
        asked.add(req.headers['Range']!);
        final from = int.parse(req.headers['Range']!.split('=')[1].split('-')[0]);
        final to = int.parse(req.headers['Range']!.split('-')[1]);
        return http.Response.bytes(List.filled(to - from + 1, 2), 206);
      });
      final total = 5 * 1024 * 1024 + 1000;
      final chunks = await InnerTubeAudioEngine.open(stream(total), 'abc').toList();
      expect(chunks.fold<int>(0, (n, c) => n + c.length), total);
      expect(asked, [
        'bytes=0-${5 * 1024 * 1024 - 1}',
        'bytes=${5 * 1024 * 1024}-${total - 1}',
      ]);
    });
  });

  test('a file larger than announced is not kept as a cache hit', () async {
    InnerTubeAudioEngine.debugPlayerOverride = (_, _) async => _ok(size: 120000);
    InnerTubeAudioEngine.debugOpenOverride =
        (url, bytes) => Stream.value(List.filled(bytes * 2, 7));
    final r = await InnerTubeAudioEngine.fetch(
      'abc',
      dir: dir,
      preferAac: false,
      shouldAbort: () => false,
    );
    expect(r.file, isNull);
    expect(r.error, contains('larger than expected'));
    expect(dir.listSync(), isEmpty);
  });

  test('fetch writes the cache file under the name the cache looks for',
      () async {
    InnerTubeAudioEngine.debugPlayerOverride = (_, _) async => _ok(size: 120000);
    InnerTubeAudioEngine.debugOpenOverride =
        (url, bytes) => Stream.value(List.filled(bytes, 7));
    final r = await InnerTubeAudioEngine.fetch(
      'abc',
      dir: dir,
      preferAac: false,
      shouldAbort: () => false,
    );
    expect(r.error, isNull);
    expect(p.basename(r.file!.path), 'abc.webm');
    expect(await r.file!.length(), 120000);
  });

  test('a cut-off transfer is not kept as a cache hit', () async {
    InnerTubeAudioEngine.debugPlayerOverride = (_, _) async => _ok(size: 120000);
    InnerTubeAudioEngine.debugOpenOverride =
        (url, bytes) => Stream.value(List.filled(60000, 7));
    final r = await InnerTubeAudioEngine.fetch(
      'abc',
      dir: dir,
      preferAac: false,
      shouldAbort: () => false,
    );
    expect(r.file, isNull);
    expect(r.error, contains('incomplete'));
    expect(dir.listSync(), isEmpty, reason: 'the partial file is removed');
  });

  test('repeated blocks rest the engine so yt-dlp takes over without more lookups',
      () async {
    var calls = 0;
    InnerTubeAudioEngine.debugPlayerOverride = (_, _) async {
      calls++;
      return _bot();
    };
    Future<BackupFetchResult> go(String id) => InnerTubeAudioEngine.fetch(
          id,
          dir: dir,
          preferAac: false,
          shouldAbort: () => false,
        );
    for (final id in ['a', 'b', 'c']) {
      expect((await go(id)).file, isNull);
    }
    final callsAfterThree = calls;
    final rested = await go('d');
    expect(rested.error, contains('resting'));
    expect(calls, callsAfterThree, reason: 'no lookup while resting');
  });

  test('videos that are merely not offered never rest the engine', () async {
    InnerTubeAudioEngine.debugPlayerOverride = (_, _) async => {
          'playabilityStatus': {'status': 'UNPLAYABLE', 'reason': 'gone'},
        };
    for (final id in ['a', 'b', 'c', 'd', 'e']) {
      final r = await InnerTubeAudioEngine.fetch(
        id,
        dir: dir,
        preferAac: false,
        shouldAbort: () => false,
      );
      expect(r.error, isNot(contains('resting')), reason: id);
    }
  });

  group('StreamCacheManager with the fast engine', () {
    final sandbox = Directory.systemTemp.createTempSync('peerm_fast_engine_');

    setUpAll(() {
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => sandbox.path);
    });

    tearDownAll(() {
      try {
        sandbox.deleteSync(recursive: true);
      } catch (_) {}
    });

    tearDown(() {
      StreamCacheManager.debugAllowFastEngineInTests = false;
      StreamCacheManager.fastEngineEnabled = true;
    });

    test('a song it can fetch is cached without starting yt-dlp', () async {
      StreamCacheManager.debugAllowFastEngineInTests = true;
      InnerTubeAudioEngine.debugPlayerOverride =
          (_, _) async => _ok(size: 90000);
      InnerTubeAudioEngine.debugOpenOverride =
          (url, bytes) => Stream.value(List.filled(bytes, 3));

      final file = await StreamCacheManager.ensureStreamCached('fastvid1');

      expect(file, isNotNull);
      expect(await file!.length(), 90000);
      expect(await StreamCacheManager.getCachedFile('fastvid1'), isNotNull);
    });

    test('a test run never reaches YouTube unless it asks to', () async {
      var lookups = 0;
      InnerTubeAudioEngine.debugPlayerOverride = (_, _) async {
        lookups++;
        return _ok();
      };
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (id, {required isPreload}) async => null;
      addTearDown(() => StreamCacheManager.debugEnsureStreamCachedOverride = null);
      await StreamCacheManager.ensureStreamCached('fastvid2');
      expect(lookups, 0);
    });
  });
}
