import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/artwork_service.dart';
import 'package:peerm_app/services/debug_log.dart';
import 'package:peerm_app/services/innertube_audio_engine.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/ram_audio_source.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';
import 'package:peerm_app/services/ytdlp_prewarmer.dart';

class _FakeProcess implements Process {
  _FakeProcess(this.pid);

  @override
  final int pid;
  bool killed = false;
  final Completer<int> _exit = Completer<int>();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(0);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAudioPlayer extends AudioPlayer {
  _FakeAudioPlayer() : super(handleAudioSessionActivation: false);

  final List<AudioSource> loaded = [];
  int playCalls = 0;
  int pauseCalls = 0;
  bool _playing = false;
  double _volume = 1.0;

  @override
  bool get playing => _playing;

  @override
  double get volume => _volume;

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => const Duration(minutes: 2);

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Stream<Duration> get positionStream => const Stream.empty();

  @override
  Stream<Duration?> get durationStream => const Stream.empty();

  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();

  @override
  Stream<PlaybackEvent> get playbackEventStream => const Stream.empty();

  @override
  Stream<ProcessingState> get processingStateStream => const Stream.empty();

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    loaded.add(source);
    return const Duration(minutes: 2);
  }

  @override
  Future<void> play() async {
    playCalls++;
    _playing = true;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing = false;
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setLoopMode(LoopMode mode) async {}
}

Song _streamSong(String videoId) => Song(
      id: 'stream_$videoId',
      title: 'Song $videoId',
      fileName: 'stream_$videoId.m4a',
      size: 0,
      checksum: 'stream_$videoId',
      sourceDeviceId: 'stream',
      addedAt: DateTime(2026, 11, 21),
    );

Map<String, dynamic> _playerOk({int size = 120000}) => {
      'playabilityStatus': {'status': 'OK'},
      'responseContext': {'visitorData': 'v613-visitor'},
      'streamingData': {
        'adaptiveFormats': [
          {
            'itag': 251,
            'mimeType': 'audio/webm; codecs="opus"',
            'averageBitrate': 128000,
            'contentLength': '$size',
            'url': 'https://v613.invalid/251',
          },
        ],
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Directory.systemTemp.createTempSync('peerm_v613_audit_');

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
    StreamCacheManager.debugSkipFallbackEngines = true;
    StreamCacheManager.clearRamCacheForTesting();
    InnerTubeAudioEngine.debugReset();
    YtDlpPrewarmer.setEnabledForTesting(null);
    YtDlpPrewarmer.debugStartProcess = null;
  });

  tearDown(() async {
    StreamCacheManager.debugEnsureStreamCachedOverride = null;
    StreamCacheManager.debugAllowFastEngineInTests = false;
    StreamCacheManager.debugSkipFallbackEngines = false;
    StreamCacheManager.cancelActiveDownload();
    StreamCacheManager.cancelPreload();
    StreamCacheManager.clearRamCacheForTesting();
    InnerTubeAudioEngine.debugReset();
    YtDlpPrewarmer.setEnabledForTesting(null);
    YtDlpPrewarmer.debugStartProcess = null;
    YtDlpPrewarmer.instance.killSpare();
    DebugLog.resetForTesting();
    DebugLog.debugBaseDirectory = null;
  });

  group('ST-06 RamAudioBuffer binary search & close wakeup', () {
    test('readSlice across many small chunks returns exact byte ranges', () {
      final buf = RamAudioBuffer(videoId: 'chunks1', ext: 'webm');
      final expected = <int>[];
      for (var c = 0; c < 400; c++) {
        final chunk = List<int>.generate(137, (j) => (c + j) & 0xff);
        expected.addAll(chunk);
        buf.append(chunk);
      }
      buf.markComplete();

      expect(buf.length, expected.length);
      for (final offset in [0, 1, 136, 137, 138, 12345, expected.length - 50]) {
        final slice = buf.readSlice(offset, 500);
        final end = (offset + 500).clamp(0, expected.length);
        expect(slice, expected.sublist(offset, end));
      }
    });

    test('RamAudioSource.close() immediately wakes a blocked reader', () async {
      final buf = RamAudioBuffer(
        videoId: 'close1',
        ext: 'webm',
        expectedLength: 1000,
      )..append([1, 2, 3]);
      final src = RamAudioSource(
        buffer: buf,
        stallTimeout: const Duration(seconds: 20),
      );
      final res = await src.request();
      final received = <int>[];
      var ended = false;
      final sub = res.stream
          .listen(received.addAll, onDone: () => ended = true);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      src.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(received, [1, 2, 3]);
      // Ending short would make just_audio's proxy throw (holdUntilHungUp);
      // the player hanging up must still end it at once.
      expect(ended, isFalse);
      await sub.cancel().timeout(const Duration(seconds: 1));
    });
  });

  group('ST-01 & ST-04 StreamCacheManager ownership & stale _resolvedStreams', () {
    test('ST-01 cancelled fetch finally does not clobber retry for same videoId',
        () async {
      StreamCacheManager.debugAllowFastEngineInTests = true;
      final firstGate = Completer<void>();
      var call = 0;
      InnerTubeAudioEngine.debugPlayerOverride = (_, _) async {
        call++;
        if (call == 1) {
          await firstGate.future;
        }
        return _playerOk(size: 80000);
      };
      InnerTubeAudioEngine.debugOpenOverride =
          (url, bytes) => Stream.value(List.filled(bytes, 5));

      // Waits on the fetch reaching YouTube, not a fixed sleep: 20 ms was
      // too short when the whole suite ran at once.
      Future<void> until(bool Function() ok) async {
        for (var i = 0; i < 500 && !ok(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(ok(), isTrue);
      }

      final first = StreamCacheManager.ensureStreamCached('samevid1');
      await until(() => call == 1);
      StreamCacheManager.cancelActiveDownload();

      final secondGate = Completer<void>();
      var secondAsked = false;
      InnerTubeAudioEngine.debugPlayerOverride = (_, _) async {
        secondAsked = true;
        await secondGate.future;
        return _playerOk(size: 80000);
      };
      final second = StreamCacheManager.ensureStreamCached('samevid1');
      await until(() => secondAsked);

      // Let the abandoned first fetch run its finally block while the second
      // fetch is still active.
      firstGate.complete();
      expect(await first, isNull);
      expect(StreamCacheManager.activeDownloadingVideoId, 'samevid1');
      expect(StreamCacheManager.getInFlightDownload('samevid1'), isNotNull);

      secondGate.complete();
      await second.timeout(const Duration(seconds: 5));
      expect(StreamCacheManager.getRamCachedBuffer('samevid1'), isNotNull);
    });

    test('ST-04 failed RamAudioBuffer is cleared from _resolvedStreams', () async {
      StreamCacheManager.debugAllowFastEngineInTests = true;
      InnerTubeAudioEngine.debugPlayerOverride =
          (_, _) async => _playerOk(size: 3000000);
      InnerTubeAudioEngine.debugOpenOverride = (url, bytes) async* {
        // Trigger onReadableBuffer (half is 1.5M), then fail short.
        yield List.filled(1600000, 1);
      };

      final published = <ResolvedStream>[];
      await StreamCacheManager.ensureStreamCached(
        'failram1',
        onStreamUrl: published.add,
      );
      expect(published, hasLength(1));
      expect(published.single.ramBuffer?.isComplete, isFalse);

      // A subsequent caller attaching onStreamUrl must not receive the failed
      // RamAudioBuffer from _resolvedStreams.
      final secondPublished = <ResolvedStream>[];
      InnerTubeAudioEngine.debugReset();
      InnerTubeAudioEngine.debugPlayerOverride =
          (_, _) async => _playerOk(size: 80000);
      InnerTubeAudioEngine.debugOpenOverride =
          (url, bytes) => Stream.value(List.filled(bytes, 2));

      await StreamCacheManager.ensureStreamCached(
        'failram1',
        onStreamUrl: secondPublished.add,
      );
      expect(secondPublished, hasLength(1));
      expect(secondPublished.single.ramBuffer?.isComplete, isTrue);
    });
  });

  group('ST-07 YtDlpPrewarmer mid-boot killSpare', () {
    test('killSpare during in-flight boot kills spawned process on arrival',
        () async {
      YtDlpPrewarmer.setEnabledForTesting(true);
      final gate = Completer<void>();
      late _FakeProcess spawned;
      YtDlpPrewarmer.debugStartProcess = (bin, args) async {
        await gate.future;
        return spawned = _FakeProcess(4242);
      };

      final boot = YtDlpPrewarmer.instance.prewarm(
        bin: 'fake-yt-dlp',
        baseArgs: const ['-f', 'bestaudio'],
        outputTemplate: '/tmp/%(id)s.%(ext)s',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      YtDlpPrewarmer.instance.killSpare();
      gate.complete();
      await boot;

      expect(spawned.killed, isTrue);
      expect(YtDlpPrewarmer.instance.hasSpare, isFalse);
    });
  });

  group('PL-01 & PL-06 PlayerService resume and smooth pause guards', () {
    test('PL-01 cancelling playSong mid-buffer makes resume reload currentSong',
        () async {
      final audio = _FakeAudioPlayer();
      final player = PlayerService(LibraryService(), player: audio);
      final s1 = _streamSong('song1111111');
      final s2 = _streamSong('song2222222');

      final f1 = File(p.join(sandbox.path, 'song1111111.webm'))
        ..writeAsBytesSync(List.filled(60000, 1));
      final s2Started = Completer<void>();
      final s2Gate = Completer<File?>();
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async {
        if (videoId == 'song1111111') return f1;
        if (!s2Started.isCompleted) s2Started.complete();
        return s2Gate.future;
      };

      await player.playSong(s1, queue: [s1, s2]);
      expect(audio.loaded, hasLength(1));

      final load2 = player.playSong(s2, queue: [s1, s2]);
      await s2Started.future.timeout(const Duration(seconds: 5));
      await player.pause();
      if (!s2Gate.isCompleted) s2Gate.complete(null);
      await load2;

      expect(player.currentSong?.id, s2.id);

      // Now provide s2 on resume and verify resume reloads s2 instead of
      // calling play() on s1's old AudioSource.
      final f2 = File(p.join(sandbox.path, 'song2222222.webm'))
        ..writeAsBytesSync(List.filled(60000, 2));
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async => f2;

      await player.resume();
      expect(audio.loaded, hasLength(2));
      expect((audio.loaded.last as UriAudioSource).uri.toFilePath(), f2.path);
      player.dispose();
    });

    test('PL-06 pause(smooth: true) does not pause if resumed during fade',
        () async {
      final audio = _FakeAudioPlayer();
      final player = PlayerService(LibraryService(), player: audio);
      final s1 = _streamSong('smooth11111');
      final f1 = File(p.join(sandbox.path, 'smooth11111.webm'))
        ..writeAsBytesSync(List.filled(60000, 1));
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async => f1;

      await player.playSong(s1, queue: [s1]);
      expect(audio.playing, isTrue);

      final pausing = player.pause(smooth: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await player.resume();
      await pausing;

      expect(audio.playing, isTrue);
      player.dispose();
    });
  });

  group('DU-01, DU-06 & DU-09 Data and DebugLog fixes', () {
    test('DU-01 LibraryService.dispose flushes pending debounced index save',
        () async {
      final dir = Directory.systemTemp.createTempSync('peerm_v613_lib_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final libDir = Directory(p.join(dir.path, 'library'))..createSync();
      File(p.join(libDir.path, 'track.mp3')).writeAsBytesSync([1, 2, 3, 4]);
      await File(p.join(dir.path, 'index.json')).writeAsString(jsonEncode([
        {
          'id': 'trk1',
          'title': 'Track',
          'fileName': 'track.mp3',
          'size': 4,
          'checksum': 'abc',
          'addedAt': '2026-11-21T00:00:00.000',
        },
      ]));

      final lib = LibraryService()..debugBaseDirectory = dir;
      await lib.init();
      lib.setSongLength('trk1', const Duration(seconds: 45));
      lib.dispose();

      // Wait briefly for the unawaited flush triggered by dispose().
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final saved = jsonDecode(
        await File(p.join(dir.path, 'index.json')).readAsString(),
      ) as List;
      expect(saved.single['durationMs'], 45000);
    });

    test('DU-06 ArtworkService.songArtworkUri overwrites 0-byte cached file',
        () async {
      final bytes = [0xff, 0xd8, 0xff, 0xe0, 1, 2, 3];
      final song = Song(
        id: 'art_zero_1',
        title: 'Art Test',
        fileName: 'art.mp3',
        size: 100,
        checksum: 'art_zero_1',
        artwork: base64Encode(bytes),
        addedAt: DateTime(2026, 11, 21),
      );
      final artFile = File(p.join(sandbox.path, 'artwork', 'song_art_zero_1.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(const []);
      expect(artFile.lengthSync(), 0);

      final uri = await ArtworkService.songArtworkUri(song);
      expect(p.equals(uri.toFilePath(), artFile.path), isTrue);
      expect(artFile.readAsBytesSync(), bytes);
    });

    test('DU-09 DebugLog batches disk appends and rotates mid-session',
        () async {
      final dir = Directory.systemTemp.createTempSync('peerm_v613_log_');
      addTearDown(() {
        DebugLog.resetForTesting();
        DebugLog.debugBaseDirectory = null;
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      DebugLog.resetForTesting();
      DebugLog.debugBaseDirectory = dir;
      // Wait for async init so subsequent lines exercise the live batching path.
      DebugLog.write('init_marker', echo: false);
      await DebugLog.flushForTesting();

      // Write enough lines to cross _maxBytes (512 KB) within one session.
      final payload = 'x' * 1024;
      for (var i = 0; i < 600; i++) {
        DebugLog.write('line_$i $payload', echo: false);
      }
      await DebugLog.flushForTesting();

      final logFile = File(p.join(dir.path, 'peerm_debug.log'));
      expect(logFile.existsSync(), isTrue);
      expect(logFile.lengthSync(), lessThanOrEqualTo(512 * 1024));
      final text = logFile.readAsStringSync();
      expect(text, contains('line_599'));
      expect(text, isNot(contains('line_0 ')));
    });
  });
}
