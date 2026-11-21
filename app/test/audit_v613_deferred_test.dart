import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/live_hls_proxy.dart';
import 'package:peerm_app/services/lyrics_service.dart';
import 'package:peerm_app/services/media_session.dart';
import 'package:peerm_app/services/pear_audio_handler.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/update_service.dart';
import 'package:peerm_app/services/video_relay.dart';
import 'package:peerm_app/widgets/player/lyrics_view.dart';

class _DeferredFakePlayer extends AudioPlayer {
  _DeferredFakePlayer() : super(handleAudioSessionActivation: false);

  final StreamController<Duration> positions = StreamController.broadcast();
  final StreamController<PlayerState> states = StreamController.broadcast();
  final StreamController<PlaybackEvent> events = StreamController.broadcast();
  final StreamController<Duration?> durations = StreamController.broadcast();
  final StreamController<ProcessingState> processingStates =
      StreamController.broadcast();

  Duration position_ = Duration.zero;
  Duration bufferedPosition_ = Duration.zero;
  Duration? duration_ = const Duration(minutes: 3);
  bool playing_ = false;
  ProcessingState processingState_ = ProcessingState.ready;
  double speed_ = 1.0;

  int stopCalls = 0;
  int setAudioSourceCalls = 0;
  Future<Duration?> Function(AudioSource source)? onSetAudioSource;

  @override
  Duration get position => position_;

  @override
  Duration get bufferedPosition => bufferedPosition_;

  @override
  Duration? get duration => duration_;

  @override
  bool get playing => playing_;

  @override
  ProcessingState get processingState => processingState_;

  @override
  double get speed => speed_;

  @override
  Stream<Duration> get positionStream => positions.stream;

  @override
  Stream<Duration?> get durationStream => durations.stream;

  @override
  Stream<PlayerState> get playerStateStream => states.stream;

  @override
  Stream<PlaybackEvent> get playbackEventStream => events.stream;

  @override
  Stream<ProcessingState> get processingStateStream => processingStates.stream;

  @override
  Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) => positions.stream;

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    setAudioSourceCalls++;
    if (onSetAudioSource != null) {
      return onSetAudioSource!(source);
    }
    return duration_;
  }

  @override
  Future<void> play() async {
    playing_ = true;
  }

  @override
  Future<void> pause() async {
    playing_ = false;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    playing_ = false;
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {
    speed_ = speed;
  }

  @override
  Future<void> setLoopMode(LoopMode mode) async {}

  @override
  Future<void> dispose() async {
    await positions.close();
    await states.close();
    await events.close();
    await durations.close();
    await processingStates.close();
  }
}

class _DirectHttpOverrides extends HttpOverrides {}

Song _makeSong(String id, {String title = 'Test Song'}) => Song(
  id: id,
  title: title,
  fileName: '$id.mp3',
  size: 1024,
  checksum: 'chk_$id',
  addedAt: DateTime(2026, 11, 21),
);

Future<(int status, List<int> bytes, Map<String, String> headers)> _httpGet(
  Uri url,
  String? range,
) async {
  final client = HttpClient();
  final req = await client.getUrl(url);
  if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
  final res = await req.close();
  final bytes = <int>[];
  await for (final chunk in res) {
    bytes.addAll(chunk);
  }
  final headers = <String, String>{
    'content-range': res.headers.value('content-range') ?? '',
    'accept-ranges': res.headers.value('accept-ranges') ?? '',
  };
  client.close();
  return (res.statusCode, bytes, headers);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final sandbox = Directory.systemTemp.createTempSync('peerm_v613_deferred_');

  setUpAll(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => sandbox.path,
    );
  });

  tearDownAll(() {
    try {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  tearDown(() async {
    LyricsService.fetchLrclibForTesting = null;
    LyricsService.clearMemoryCache();
    MediaSession.dispose();
    debugDefaultTargetPlatformOverride = null;
    PlayerService.earlyStreamOpenTimeout = const Duration(seconds: 10);
    LiveHlsProxy.stop();
    VideoRelay.idleTimeout = const Duration(seconds: 8);
    VideoRelay.windowTime = const Duration(seconds: 4);
    VideoRelay.stop();
    messenger.setMockMethodCallHandler(
      const MethodChannel('peerm/media_session'),
      null,
    );
  });

  group('DU-03 LyricsService deduplication and atomic temp filenames', () {
    test('concurrent getLyrics calls share one in-flight online lookup',
        () async {
      final song = _makeSong('du03_dedup_song', title: 'Placeholder Song');
      final gate = Completer<void>();
      final fetchStarted = Completer<void>();
      var fetchCalls = 0;
      LyricsService.fetchLrclibForTesting = (_, {Duration? duration}) async {
        fetchCalls++;
        if (!fetchStarted.isCompleted) fetchStarted.complete();
        await gate.future;
        return '[00:00.00] Line 1\n[00:05.00] Line 2';
      };

      final f1 = LyricsService.getLyrics(song);
      final f2 = LyricsService.getLyrics(song);
      await fetchStarted.future.timeout(const Duration(seconds: 2));
      expect(fetchCalls, 1);

      gate.complete();
      final results = await Future.wait([f1, f2]);
      expect(fetchCalls, 1);
      expect(results[0], hasLength(2));
      expect(results[1], hasLength(2));

      final cacheFile = File(
        p.join(sandbox.path, 'lyrics_cache', 'du03_dedup_song.lrc'),
      );
      expect(cacheFile.existsSync(), isTrue);
    });

    test('concurrent writeFileAtomicallyForTesting leaves no .tmp files',
        () async {
      final dir = Directory(p.join(sandbox.path, 'du03_atomic'))
        ..createSync(recursive: true);
      final targetPath = p.join(dir.path, 'track.lrc');

      await Future.wait([
        for (var i = 0; i < 8; i++)
          LyricsService.writeFileAtomicallyForTesting(
            targetPath,
            '[00:00.00] Placeholder batch $i\n',
          ),
      ]);

      final written = File(targetPath).readAsStringSync();
      expect(written, startsWith('[00:00.00] Placeholder batch '));
      final leftovers = dir
          .listSync()
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });

  group('DU-07 UpdateDialog hostContext survives dialog pop', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
      testWidgets(
        'missing hash dialog still appears after popping on ${platform.name}',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          try {
            final info = UpdateInfo(
              hasUpdate: true,
              currentVersion: '6.1.2',
              latestVersion: '6.1.3',
              releaseNotes: 'Placeholder release notes',
              htmlUrl: 'https://example.com/release',
              zipUrl: 'https://example.com/PearMusic-Windows-x64.zip',
              apkUrl: 'https://example.com/PearMusic-Android-arm64.apk',
              verified: true,
              sha256ByName: const {},
            );

            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: Builder(
                    builder: (hostCtx) => TextButton(
                      onPressed: () =>
                          UpdateService.showUpdateDialogFor(hostCtx, info),
                      child: const Text('Open Update'),
                    ),
                  ),
                ),
              ),
            );

            await tester.tap(find.text('Open Update'));
            await tester.pumpAndSettle();

            final actionLabel = platform == TargetPlatform.windows
                ? 'Update Automatically'
                : 'Download APK';
            expect(find.text(actionLabel), findsOneWidget);

            await tester.tap(find.text(actionLabel));
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pumpAndSettle();

            expect(find.text('Cannot verify update'), findsOneWidget);
            await tester.tap(find.text('Cancel'));
            await tester.pumpAndSettle();
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        },
      );
    }
  });

  group('DU-10 Virtualized scrolling LyricsView', () {
    testWidgets(
      'bounds animations, hides scrollbars, and two-pass centers off-screen line',
      (tester) async {
        final song = _makeSong('du10_long_song', title: 'Long Song');
        final lrc = [
          for (var i = 0; i < 120; i++)
            '[${(i ~/ 60).toString().padLeft(2, '0')}:'
                '${(i % 60).toString().padLeft(2, '0')}.00] Line $i',
        ].join('\n');
        LyricsService.setLyricsForTesting(song.id, lrc);

        final engine = _DeferredFakePlayer()..position_ = Duration.zero;
        final player = PlayerService(LibraryService(), player: engine);
        addTearDown(() async {
          player.dispose();
          await engine.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 320,
                height: 360,
                child: LyricsView(
                  song: song,
                  player: player,
                  size: 320,
                  scrolling: true,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byType(Scrollbar), findsNothing);
        expect(find.byType(RawScrollbar), findsNothing);
        expect(find.byType(AnimatedScale).evaluate().length, lessThanOrEqualTo(4));
        expect(
          find.byType(AnimatedDefaultTextStyle).evaluate().length,
          lessThanOrEqualTo(4),
        );
        expect(find.text('Line 90'), findsNothing);

        // Jump to Line 90 (90s = 01:30.00), well outside the initial viewport.
        const targetPos = Duration(seconds: 90);
        engine.position_ = targetPos;
        engine.positions.add(targetPos);
        await tester.pump();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pump(const Duration(milliseconds: 700));

        expect(find.text('Line 90'), findsOneWidget);
        final panel = tester.getRect(find.byType(LyricsView));
        final target = tester.getRect(find.text('Line 90'));
        expect((target.center.dy - panel.center.dy).abs(), lessThan(4));
        expect(find.byType(AnimatedScale).evaluate().length, lessThanOrEqualTo(4));
      },
    );
  });

  group('PL-07 MediaSession coalescing, filtering, and dispose', () {
    test('coalesces overlapping pushes, skips unrelated notifies, and disposes',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final calls = <String>[];
      Completer<void>? metadataGate;

      messenger.setMockMethodCallHandler(
        const MethodChannel('peerm/media_session'),
        (call) async {
          calls.add(call.method);
          final gate = metadataGate;
          if (call.method == 'setMetadata' && gate != null) {
            await gate.future;
          }
          return null;
        },
      );

      final engine = _DeferredFakePlayer();
      final player = PlayerService(LibraryService(), player: engine);
      addTearDown(() async {
        player.dispose();
        await engine.dispose();
      });

      MediaSession.init(player);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      calls.clear();

      // Unrelated notifyListeners() (toggleShuffle) must not push timeline.
      player.toggleShuffle();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, isNot(contains('setTimeline')));

      // Overlapping pushState calls while setMetadata is in flight coalesce
      // instead of executing concurrently.
      metadataGate = Completer<void>();
      player.currentSong = _makeSong('pl07_s1', title: 'Track One');
      player.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      player.notifyListeners();
      player.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls.where((c) => c == 'setMetadata'), hasLength(1));

      metadataGate.complete();
      metadataGate = null;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls.where((c) => c == 'setMetadata'), hasLength(1));
      expect(calls, contains('setTimeline'));

      // Dispose detaches listener and cancels timer.
      MediaSession.dispose();
      calls.clear();
      player.currentSong = _makeSong('pl07_s2', title: 'Track Two');
      player.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, isEmpty);
    });
  });

  group('PL-09 Live stream seek resets hung engine via _openSource', () {
    test('timeout on seekLive calls stop, restores liveBehind, and recovers',
        () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        PlayerService.earlyStreamOpenTimeout = const Duration(milliseconds: 100);
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => upstream.close(force: true));
        upstream.listen((req) async {
          req.response.statusCode = 200;
          req.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:5\n');
          await req.response.close();
        });
        await LiveHlsProxy.serve('http://127.0.0.1:${upstream.port}/live.m3u8');

        final engine = _DeferredFakePlayer();
        var hangFirst = true;
        engine.onSetAudioSource = (_) {
          if (hangFirst) {
            hangFirst = false;
            return Completer<Duration?>().future;
          }
          return Future.value(null);
        };

        final player = PlayerService(LibraryService(), player: engine);
        addTearDown(() async {
          player.dispose();
          await engine.dispose();
        });

        player.debugSetLive(true);
        await player.seekLive(30).timeout(const Duration(seconds: 2));

        expect(engine.stopCalls, 1);
        expect(player.liveBehind, 0);

        await player.seekLive(30).timeout(const Duration(seconds: 2));
        expect(engine.setAudioSourceCalls, 2);
        expect(player.liveBehind, greaterThanOrEqualTo(30));
      }, _DirectHttpOverrides());
    });
  });

  group('PL-10 playbackEventStream notification throttling', () {
    test('burst of identical playback events produces at most one push',
        () async {
      final engine = _DeferredFakePlayer()
        ..playing_ = false
        ..processingState_ = ProcessingState.ready
        ..position_ = const Duration(seconds: 10);
      final handler = PearAudioHandler();
      final player = PlayerService(
        LibraryService(),
        player: engine,
        audioHandler: handler,
      );
      await player.init();
      addTearDown(() async {
        player.dispose();
        await engine.dispose();
      });

      final pushed = <PlaybackState>[];
      final sub = handler.playbackState.listen(pushed.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      pushed.clear();

      for (var i = 0; i < 15; i++) {
        engine.events.add(PlaybackEvent());
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(pushed, isEmpty);

      // Large position jump pushes immediately.
      engine.position_ = const Duration(seconds: 25);
      engine.events.add(PlaybackEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(pushed, hasLength(1));

      // Discrete playing state change pushes immediately.
      engine.playing_ = true;
      engine.events.add(PlaybackEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(pushed, hasLength(2));
    });
  });

  group('ST-09 VideoRelay head cache range, overlap, and relink generation', () {
    test('does not serve partial _head when Range header is omitted',
        () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final body = Uint8List.fromList(
          List<int>.generate(VideoRelay.windowBytes + 4096, (i) => i % 251),
        );
        var upstreamCalls = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          upstreamCalls++;
          final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(
            req.headers.value(HttpHeaders.rangeHeader) ?? '',
          )!;
          final start = int.parse(m.group(1)!);
          final end = int.parse(m.group(2)!).clamp(0, body.length - 1);
          req.response.statusCode = 206;
          req.response.headers
            ..set('content-range', 'bytes $start-$end/${body.length}')
            ..contentLength = end - start + 1;
          req.response.add(body.sublist(start, end + 1));
          await req.response.close();
        });

        final local = await VideoRelay.serve(
          'http://127.0.0.1:${server.port}/v.mp4',
        );
        // Warm _head via ranged request.
        await _httpGet(local, 'bytes=0-${VideoRelay.headMin + 1023}');
        expect(upstreamCalls, 1);

        // Unranged request must go upstream for a full window rather than
        // returning the partial _head cache.
        final (status, bytes, _) = await _httpGet(local, null);
        expect(status, 206);
        expect(bytes.length, VideoRelay.windowBytes);
        expect(upstreamCalls, 2);
      }, _DirectHttpOverrides());
    });

    test('overlapping range fills extend _head cleanly', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final body = Uint8List.fromList(
          List<int>.generate(VideoRelay.windowBytes + 4096, (i) => i % 241),
        );
        var upstreamCalls = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          upstreamCalls++;
          final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(
            req.headers.value(HttpHeaders.rangeHeader) ?? '',
          )!;
          final start = int.parse(m.group(1)!);
          final end = int.parse(m.group(2)!).clamp(0, body.length - 1);
          req.response.statusCode = 206;
          req.response.headers
            ..set('content-range', 'bytes $start-$end/${body.length}')
            ..contentLength = end - start + 1;
          req.response.add(body.sublist(start, end + 1));
          await req.response.close();
        });

        final local = await VideoRelay.serve(
          'http://127.0.0.1:${server.port}/v.mp4',
        );
        const firstEnd = 300 * 1024 - 1;
        await _httpGet(local, 'bytes=0-$firstEnd');
        const secondEnd = 600 * 1024 - 1;
        await _httpGet(local, 'bytes=${200 * 1024}-$secondEnd');
        expect(upstreamCalls, 2);

        // A ranged read up to 600 KB is now served entirely from _head.
        final (status, bytes, _) = await _httpGet(local, 'bytes=0-$secondEnd');
        expect(status, 206);
        expect(bytes, body.sublist(0, secondEnd + 1));
        expect(upstreamCalls, 2);
      }, _DirectHttpOverrides());
    });

    test('stale chunks from pre-relink URL do not pollute _head', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final oldBody = Uint8List.fromList(List<int>.filled(1024 * 1024, 0x11));
        final newBody = Uint8List.fromList(List<int>.filled(1024 * 1024, 0x22));
        final firstChunkSent = Completer<void>();
        final allowOldSecondChunk = Completer<void>();
        final oldChunkDone = Completer<void>();
        var failOld = false;

        final oldServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => oldServer.close(force: true));
        oldServer.listen((req) async {
          if (failOld) {
            req.response.statusCode = HttpStatus.forbidden;
            await req.response.close();
            return;
          }
          req.response.statusCode = 206;
          req.response.headers
            ..set('content-range', 'bytes 0-${512 * 1024 - 1}/${oldBody.length}')
            ..contentLength = 512 * 1024;
          req.response.add(oldBody.sublist(0, 128 * 1024));
          await req.response.flush();
          if (!firstChunkSent.isCompleted) firstChunkSent.complete();
          await allowOldSecondChunk.future;
          req.response.add(oldBody.sublist(128 * 1024, 512 * 1024));
          await req.response.close();
          if (!oldChunkDone.isCompleted) oldChunkDone.complete();
        });

        final newServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => newServer.close(force: true));
        var newCalls = 0;
        newServer.listen((req) async {
          newCalls++;
          final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(
            req.headers.value(HttpHeaders.rangeHeader) ?? '',
          )!;
          final start = int.parse(m.group(1)!);
          final end = int.parse(m.group(2)!).clamp(0, newBody.length - 1);
          req.response.statusCode = 206;
          req.response.headers
            ..set('content-range', 'bytes $start-$end/${newBody.length}')
            ..contentLength = end - start + 1;
          req.response.add(newBody.sublist(start, end + 1));
          await req.response.close();
        });

        final local = await VideoRelay.serve(
          'http://127.0.0.1:${oldServer.port}/old.mp4',
          relink: () async => (
            url: 'http://127.0.0.1:${newServer.port}/new.mp4',
            headers: <String, String>{},
          ),
        );

        final staleReq = _httpGet(local, 'bytes=0-${512 * 1024 - 1}');
        await firstChunkSent.future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Trigger relink from another range request; this clears _head and bumps generation.
        failOld = true;
        final relinkedRead = await _httpGet(
          local,
          'bytes=${512 * 1024}-${768 * 1024 - 1}',
        );
        expect(relinkedRead.$1, 206);
        expect(relinkedRead.$2.first, 0x22);

        // Let the pre-relink stream finish its remaining old chunks.
        allowOldSecondChunk.complete();
        await oldChunkDone.future;
        await staleReq;

        // Subsequent bytes=0- must hit newServer and return 0x22 bytes, never old 0x11 bytes.
        final callsBefore = newCalls;
        final freshHead = await _httpGet(local, 'bytes=0-${300 * 1024 - 1}');
        expect(newCalls, callsBefore + 1);
        expect(freshHead.$2.every((b) => b == 0x22), isTrue);
      }, _DirectHttpOverrides());
    });
  });
}
