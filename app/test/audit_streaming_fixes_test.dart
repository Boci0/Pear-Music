import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:peerm_app/services/growing_file_audio_source.dart';
import 'package:peerm_app/services/innertube_audio_engine.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';
import 'package:peerm_app/services/video_relay.dart';
import 'package:peerm_app/services/youtube_search_service.dart';
import 'package:peerm_app/services/ytdlp_prewarmer.dart';

/// Regression tests for the streaming audit fixes:
/// S-01 (a file being written is not a cache hit), S-02 (join first, abandon
/// cleanly, preserve semantics), S-04 (quota pass does not touch in-flight
/// files), S-09 (growing source handle on close during open), S-10 (single
/// flight prewarm), S-11 (visitor-id retry arms the guard), S-13 (relay head
/// reset on relink), S-14 (live-search client closed on dispose).
///
/// The fast engine stands in for a real fetch through its existing seams; no
/// test reaches YouTube, yt-dlp or the Android plugin.

Map<String, dynamic> _audioResponse({int size = 200000}) => {
  'playabilityStatus': {'status': 'OK'},
  'responseContext': {'visitorData': 'audit-visitor'},
  'streamingData': {
    'adaptiveFormats': [
      {
        'itag': 140,
        'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
        'averageBitrate': 128000,
        'contentLength': '$size',
        'url': 'https://audit.invalid/140',
      },
    ],
  },
};

Future<void> _until(bool Function() ok) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ok() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: 'condition did not become true in time');
}

/// A process the prewarmer can hold and kill without spawning a real helper.
class _FakeProcess implements Process {
  _FakeProcess(this.pid);

  @override
  final int pid;

  final Completer<int> _exit = Completer<int>();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) _exit.complete(0);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One picture file served from loopback, with ranged reads and a switch that
/// makes every read fail the way an expired link does.
class _RelayUpstream {
  _RelayUpstream(this.body);

  final Uint8List body;
  late final HttpServer server;
  bool refuse = false;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (refuse) {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      final range = req.headers.value(HttpHeaders.rangeHeader) ?? '';
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      if (m == null) {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType('video', 'mp4');
        req.response.add(body);
        await req.response.close();
        return;
      }
      final start = int.parse(m.group(1)!);
      final endRaw = m.group(2)!;
      final end = endRaw.isEmpty
          ? body.length - 1
          : int.parse(endRaw).clamp(0, body.length - 1);
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers
        ..set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${body.length}')
        ..set(HttpHeaders.contentTypeHeader, 'video/mp4')
        ..contentLength = end - start + 1;
      req.response.add(body.sublist(start, end + 1));
      await req.response.close();
    });
  }

  String get url => 'http://127.0.0.1:${server.port}/v.mp4';
}

Future<({int status, Uint8List body})> _relayGet(Uri url, String? range) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(url);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final res = await req.close();
    final out = BytesBuilder(copy: false);
    await for (final chunk in res) {
      out.add(chunk);
    }
    return (status: res.statusCode, body: out.takeBytes());
  } finally {
    client.close(force: true);
  }
}

class _CountingClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      throw UnimplementedError('the audit test never sends a request');

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Directory.systemTemp.createTempSync('peerm_audit_streaming_');

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
    StreamCacheManager.debugEnsureStreamCachedOverride = null;
    StreamCacheManager.debugAllowFastEngineInTests = false;
    StreamCacheManager.debugSkipFallbackEngines = false;
    StreamCacheManager.fastEngineEnabled = true;
    StreamCacheManager.cancelActiveDownload();
    StreamCacheManager.cancelPreload();
    InnerTubeAudioEngine.debugReset();
    YtDlpPrewarmer.setEnabledForTesting(false);
    YtDlpPrewarmer.debugStartProcess = null;
  });

  tearDown(() {
    StreamCacheManager.debugEnsureStreamCachedOverride = null;
    StreamCacheManager.debugAllowFastEngineInTests = false;
    StreamCacheManager.debugSkipFallbackEngines = false;
    StreamCacheManager.cancelActiveDownload();
    StreamCacheManager.cancelPreload();
    InnerTubeAudioEngine.debugReset();
    YtDlpPrewarmer.setEnabledForTesting(null);
    YtDlpPrewarmer.debugStartProcess = null;
    YtDlpPrewarmer.instance.killSpare();
    VideoRelay.stop();
  });

  group('S-01 in-flight cache files are not cache hits', () {
    test('getCachedFile hides a file the fetch is still writing', () async {
      StreamCacheManager.debugAllowFastEngineInTests = true;
      InnerTubeAudioEngine.debugPlayerOverride =
          (_, _) async => _audioResponse(size: 90000);
      final gate = Completer<void>();
      InnerTubeAudioEngine.debugOpenOverride = (url, bytes) async* {
        await gate.future;
        yield List.filled(bytes, 1);
      };

      final fetch = StreamCacheManager.ensureStreamCached('auditinflight1');
      await _until(
        () => StreamCacheManager.getInFlightDownload('auditinflight1') != null,
      );

      // What a yt-dlp phase leaves on disk while it downloads: the final name,
      // already larger than the cache's 50 KB minimum.
      final dir = await StreamCacheManager.getCacheDirectory();
      final writing = File(p.join(dir.path, 'auditinflight1.webm'))
        ..writeAsBytesSync(List.filled(60000, 1));

      expect(
        await StreamCacheManager.getCachedFile('auditinflight1'),
        isNull,
        reason: 'a file being written must never be served as a cache hit',
      );
      expect(
        await StreamCacheManager.getCachedFile(
          'auditinflight1',
          allowWhileDownloading: true,
        ),
        isNotNull,
        reason: 'the fetch itself may adopt the file it just finished writing',
      );

      gate.complete();
      final file = await fetch.timeout(const Duration(seconds: 10));
      expect(file, isNotNull);
      expect(writing.existsSync(), isTrue);
      expect(
        await StreamCacheManager.getCachedFile('auditinflight1'),
        isNotNull,
        reason: 'once the fetch is over the file is an ordinary cache hit',
      );
    });
  });

  group('S-02 join first, abandon cleanly, preserve semantics', () {
    test('a second caller joins the running fetch instead of fetching again',
        () async {
      StreamCacheManager.debugAllowFastEngineInTests = true;
      var lookups = 0;
      final gate = Completer<void>();
      InnerTubeAudioEngine.debugPlayerOverride = (_, _) async {
        lookups++;
        await gate.future;
        return _audioResponse(size: 90000);
      };
      InnerTubeAudioEngine.debugOpenOverride =
          (url, bytes) => Stream.value(List.filled(bytes, 7));

      final first = StreamCacheManager.ensureStreamCached('auditjoin1');
      await _until(
        () => StreamCacheManager.getInFlightDownload('auditjoin1') != null,
      );
      final second = StreamCacheManager.ensureStreamCached('auditjoin1');
      gate.complete();

      final results = await Future.wait([first, second])
          .timeout(const Duration(seconds: 10));
      expect(results[0], isNotNull);
      expect(identical(results[0], results[1]), isTrue,
          reason: 'both callers must get the same cached file');
      expect(lookups, 1, reason: 'joining must not start a second engine');
    });

    test('a cancelled fetch does not fall through to a fallback engine',
        () async {
      StreamCacheManager.debugAllowFastEngineInTests = true;
      StreamCacheManager.debugSkipFallbackEngines = true;
      var lookups = 0;
      InnerTubeAudioEngine.debugPlayerOverride = (_, _) async {
        lookups++;
        return _audioResponse(size: 200000);
      };
      final gate = Completer<void>();
      InnerTubeAudioEngine.debugOpenOverride = (url, bytes) async* {
        await gate.future;
        yield List.filled(bytes, 1);
      };

      final fetch = StreamCacheManager.ensureStreamCached('auditabandon1');
      // The fast engine has picked the stream and is waiting on its first
      // bytes when the cancel arrives.
      await _until(() => lookups == 1);
      StreamCacheManager.cancelActiveDownload();
      gate.complete();

      expect(await fetch.timeout(const Duration(seconds: 10)), isNull);
      expect(lookups, 1, reason: 'the aborted fast engine is not retried');
      expect(
        StreamCacheManager.takeFetchFailure('auditabandon1'),
        isNull,
        reason: 'no fallback engine ran, so no failure was recorded',
      );
    });

    test('cancelActiveDownload preserving the active fetch leaves it running',
        () async {
      StreamCacheManager.debugAllowFastEngineInTests = true;
      StreamCacheManager.debugSkipFallbackEngines = true;
      var lookups = 0;
      InnerTubeAudioEngine.debugPlayerOverride = (_, _) async {
        lookups++;
        return _audioResponse(size: 90000);
      };
      final gate = Completer<void>();
      InnerTubeAudioEngine.debugOpenOverride = (url, bytes) async* {
        await gate.future;
        yield List.filled(bytes, 1);
      };

      final fetch = StreamCacheManager.ensureStreamCached('auditpreserve1');
      await _until(
        () => StreamCacheManager.getInFlightDownload('auditpreserve1') != null,
      );
      // The player is about to play the track this fetch is downloading.
      StreamCacheManager.cancelActiveDownload(exceptVideoId: 'auditpreserve1');
      gate.complete();

      final file = await fetch.timeout(const Duration(seconds: 10));
      expect(file, isNotNull,
          reason: 'a preserved download must not be aborted by the token bump');
      expect(lookups, 1);
    });

    test('cancelPreload preserving an active preload keeps that fetch alive',
        () async {
      StreamCacheManager.debugAllowFastEngineInTests = true;
      StreamCacheManager.debugSkipFallbackEngines = true;
      var lookups = 0;
      InnerTubeAudioEngine.debugPlayerOverride = (_, _) async {
        lookups++;
        return _audioResponse(size: 90000);
      };
      final gate = Completer<void>();
      InnerTubeAudioEngine.debugOpenOverride = (url, bytes) async* {
        await gate.future;
        yield List.filled(bytes, 1);
      };

      final fetch = StreamCacheManager.ensureStreamCached(
        'auditpreserve2',
        isPreload: true,
      );
      await _until(
        () => StreamCacheManager.getInFlightDownload('auditpreserve2') != null,
      );
      // What playback does when it starts playing the preloaded track.
      StreamCacheManager.cancelPreload(exceptVideoId: 'auditpreserve2');
      StreamCacheManager.cancelActiveDownload(exceptVideoId: 'auditpreserve2');
      gate.complete();

      final file = await fetch.timeout(const Duration(seconds: 10));
      expect(file, isNotNull,
          reason: 'the stale preload sequence must not abort a preserved fetch');
      expect(lookups, 1);
    });
  });

  group('S-04 quota enforcement', () {
    test('a file a fetch is still writing is never evicted', () async {
      final dir = await StreamCacheManager.getCacheDirectory();
      for (final entity in dir.listSync()) {
        if (entity is File) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }

      StreamCacheManager.debugAllowFastEngineInTests = true;
      StreamCacheManager.debugSkipFallbackEngines = true;
      InnerTubeAudioEngine.debugPlayerOverride =
          (_, _) async => _audioResponse(size: 200000);
      final gate = Completer<void>();
      InnerTubeAudioEngine.debugOpenOverride = (url, bytes) async* {
        await gate.future;
        yield List.filled(bytes, 1);
      };

      final fetch = StreamCacheManager.ensureStreamCached('auditquota1');
      await _until(
        () => StreamCacheManager.getInFlightDownload('auditquota1') != null,
      );

      // The oldest file in the cache, but a fetch is writing it right now.
      final writing = File(p.join(dir.path, 'auditquota1.webm'))
        ..writeAsBytesSync(List.filled(60000, 1));
      writing.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 30)),
      );
      for (var i = 0; i < StreamCacheManager.maxTrackCount + 1; i++) {
        final f = File(
          p.join(dir.path, 'auditkeep${i.toString().padLeft(3, '0')}.m4a'),
        )..writeAsBytesSync([1, 2, 3]);
        f.setLastModifiedSync(
          DateTime.now().subtract(Duration(minutes: 100 - i)),
        );
      }

      await StreamCacheManager.enforceCacheQuota();
      expect(writing.existsSync(), isTrue,
          reason: 'eviction must not delete a file that is being written');

      gate.complete();
      await fetch.timeout(const Duration(seconds: 10));
    });
  });

  group('S-09 growing source close during open', () {
    test('close while the file is opening releases the handle and fails',
        () async {
      final dir = Directory.systemTemp.createTempSync('peerm_audit_growing_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final path = p.join(dir.path, 'closed.m4a');
      File(path).writeAsBytesSync([1, 2, 3]);
      final done = Completer<void>();
      final source = GrowingFileAudioSource(
        path: path,
        done: done.future,
        pollInterval: const Duration(milliseconds: 5),
        openTimeout: const Duration(seconds: 2),
        stallTimeout: const Duration(seconds: 2),
      );

      final pending = source.request();
      // close() runs before the file handle has finished opening.
      final closing = source.close();

      await expectLater(pending, throwsA(isA<StateError>()));
      await closing;
      done.complete();
      // The handle was released: Windows refuses this delete while it is open.
      File(path).deleteSync();
      expect(File(path).existsSync(), isFalse);
    });
  });

  group('S-10 prewarm single flight', () {
    test('overlapping prewarm calls boot one spare', () async {
      YtDlpPrewarmer.setEnabledForTesting(true);
      var starts = 0;
      final gate = Completer<void>();
      YtDlpPrewarmer.debugStartProcess = (bin, args) async {
        starts++;
        await gate.future;
        return _FakeProcess(9000 + starts);
      };

      final a = YtDlpPrewarmer.instance.prewarm(
        bin: 'audit-yt-dlp',
        baseArgs: const ['-f', 'bestaudio'],
        outputTemplate: '/tmp/%(id)s.%(ext)s',
      );
      final b = YtDlpPrewarmer.instance.prewarm(
        bin: 'audit-yt-dlp',
        baseArgs: const ['-f', 'bestaudio'],
        outputTemplate: '/tmp/%(id)s.%(ext)s',
      );
      gate.complete();
      await Future.wait([a, b]).timeout(const Duration(seconds: 5));

      expect(starts, 1, reason: 'one boot, not one per caller');
      expect(YtDlpPrewarmer.instance.hasSpare, isTrue);
      YtDlpPrewarmer.instance.killSpare();
      expect(YtDlpPrewarmer.instance.hasSpare, isFalse);
    });
  });

  group('S-11 visitor-id retry arms the engine guard', () {
    test('a failure during the visitor-id retry backs the engine off', () async {
      final dir = Directory.systemTemp.createTempSync('peerm_audit_innertube_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      var calls = 0;
      InnerTubeAudioEngine.debugPlayerOverride = (_, visitorData) async {
        calls++;
        if (visitorData == null) {
          return {
            'playabilityStatus': {'status': 'LOGIN_REQUIRED'},
            'responseContext': {'visitorData': 'audit-visitor'},
          };
        }
        throw InnerTubeFailure('player HTTP 500', systemic: true);
      };

      Future<String?> errorFor(String id) async => (await InnerTubeAudioEngine
              .fetch(id, dir: dir, preferAac: false, shouldAbort: () => false))
          .error;

      await errorFor('auditiv1');
      await errorFor('auditiv2');
      await errorFor('auditiv3');
      final callsBefore = calls;
      final rested = await errorFor('auditiv4');

      expect(rested, contains('resting'),
          reason: 'three guarded failures must pause the engine');
      expect(calls, callsBefore,
          reason: 'no lookup is made while the engine is resting');
    });
  });

  group('S-13 video relay head cache', () {
    test('a relink drops the cached start of the old file', () async {
      final bodyA = Uint8List.fromList(List.filled(300 * 1024, 65));
      final bodyB = Uint8List.fromList(List.filled(300 * 1024, 66));
      final oldUpstream = _RelayUpstream(bodyA);
      final newUpstream = _RelayUpstream(bodyB);
      await oldUpstream.start();
      await newUpstream.start();

      // TestWidgetsFlutterBinding routes every HttpClient to a 400 mock. The
      // relay talks to its upstream over loopback, so real sockets are needed
      // for this test only.
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        final local = await VideoRelay.serve(
          oldUpstream.url,
          client: HttpClient(),
          relink: () async =>
              (url: newUpstream.url, headers: const <String, String>{}),
        );

        final first = await _relayGet(local, 'bytes=0-');
        expect(first.body.length, bodyA.length,
            reason: 'the start is one window of the old file');
        expect(first.body[0], 65, reason: 'the start comes from the old link');

        // The old link expires and the relay swaps in the new one.
        oldUpstream.refuse = true;
        final second = await _relayGet(local, 'bytes=100000-');
        expect(second.body[0], 66, reason: 'the rest comes from the new link');

        final third = await _relayGet(local, 'bytes=0-');
        expect(third.body[0], 66,
            reason:
                'after a relink the start must be read again from the new file');
      } finally {
        HttpOverrides.global = overrides;
        VideoRelay.stop();
        await oldUpstream.server.close(force: true);
        await newUpstream.server.close(force: true);
      }
    });
  });

  group('S-14 search service dispose', () {
    test('dispose closes the live-search client', () {
      final client = _CountingClient();
      YouTubeSearchService.debugSetLiveClient(client);
      expect(YouTubeSearchService.debugHasLiveClient, isTrue);

      YouTubeSearchService.dispose();

      expect(client.closed, isTrue);
      expect(YouTubeSearchService.debugHasLiveClient, isFalse);
    });
  });
}
