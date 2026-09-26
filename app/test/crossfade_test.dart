import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/loudness_meter.dart';
import 'package:peerm_app/services/loudness_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

Song _streamSong(String videoId) => Song(
      id: 'stream_$videoId',
      title: 'Song $videoId',
      fileName: 'stream_$videoId.m4a',
      size: 0,
      checksum: 'stream_$videoId',
      sourceDeviceId: 'stream',
      addedAt: DateTime(2026, 9, 26),
    );

/// Records what playback asks of an engine. The main player reports a
/// one-minute song and whatever [position] a test sets.
class _FakePlayer extends AudioPlayer {
  _FakePlayer() : super(handleAudioSessionActivation: false);

  final List<String> loaded = [];
  final List<double> volumes = [];
  Duration position_ = Duration.zero;
  double _volume = 1.0;
  bool _playing = false;
  int stops = 0;

  @override
  double get volume => _volume;

  @override
  bool get playing => _playing;

  @override
  Duration get position => position_;

  @override
  Duration? get duration => const Duration(minutes: 1);

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    volumes.add(volume);
  }

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    loaded.add(p.basename((source as UriAudioSource).uri.toFilePath()));
    return const Duration(minutes: 1);
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (position != null) position_ = position;
  }

  @override
  Future<void> play() async => _playing = true;

  @override
  Future<void> pause() async => _playing = false;

  @override
  Future<void> stop() async {
    _playing = false;
    stops++;
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setLoopMode(LoopMode mode) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Directory.systemTemp.createTempSync('peerm_crossfade_');
  setUpAll(() async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => sandbox.path);
    // Both songs are already cached, like a preloaded next song.
    final cache = await StreamCacheManager.getCacheDirectory();
    for (final id in ['aaaaaaaaaaa', 'bbbbbbbbbbb']) {
      File(p.join(cache.path, '$id.m4a')).writeAsBytesSync(List.filled(60000, 1));
      await StreamCacheManager.getCachedFile(id);
    }
  });
  tearDownAll(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<(_FakePlayer, _FakePlayer, PlayerService)> playFirst({
    required int crossfadeSeconds,
  }) async {
    final main = _FakePlayer();
    final tail = _FakePlayer();
    final player = PlayerService(
      LibraryService(),
      player: main,
      tailPlayerFactory: () => tail,
    );
    await player.setLoudnessNormalization(false);
    await player.setCrossfadeSeconds(crossfadeSeconds);
    final first = _streamSong('aaaaaaaaaaa');
    final second = _streamSong('bbbbbbbbbbb');
    await player.playSong(first, queue: [first, second]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return (main, tail, player);
  }

  test('near the end the song hands over to the next one while it fades out',
      () async {
    final (main, tail, player) = await playFirst(crossfadeSeconds: 1);
    main.position_ = const Duration(seconds: 59, milliseconds: 200);

    player.debugCrossfadeTick(main.position_);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(tail.loaded, ['aaaaaaaaaaa.m4a'],
        reason: 'the tail finishes the ending song from its own file');
    expect(tail.position_, const Duration(seconds: 59, milliseconds: 200));
    expect(tail.playing, isTrue);
    expect(main.loaded, ['aaaaaaaaaaa.m4a', 'bbbbbbbbbbb.m4a'],
        reason: 'the main player moves on without waiting for the end');
    expect(player.currentSong?.id, 'stream_bbbbbbbbbbb');

    // The fades run on real timers; wait for them rather than a fixed time
    // so a busy machine does not fail the test.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline) &&
        (tail.stops == 0 || (main.volume - player.volume).abs() > 0.001)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(tail.volumes.last, closeTo(0, 0.001));
    expect(tail.stops, greaterThan(0), reason: 'the tail stops once faded out');
    expect(main.volume, closeTo(player.volume, 0.001),
        reason: 'the next song has faded all the way in');
  });

  test('crossfade off lets the song play to its end', () async {
    final (main, tail, player) = await playFirst(crossfadeSeconds: 0);
    main.position_ = const Duration(seconds: 59, milliseconds: 200);
    player.debugCrossfadeTick(main.position_);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(tail.loaded, isEmpty);
    expect(main.loaded, ['aaaaaaaaaaa.m4a']);
  });

  test('before the fade window nothing happens', () async {
    final (main, tail, player) = await playFirst(crossfadeSeconds: 1);
    main.position_ = const Duration(seconds: 50);
    player.debugCrossfadeTick(main.position_);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(tail.loaded, isEmpty);
    expect(player.currentSong?.id, 'stream_aaaaaaaaaaa');
  });

  test('pausing during the fade silences the ending song too', () async {
    final (main, tail, player) = await playFirst(crossfadeSeconds: 1);
    main.position_ = const Duration(seconds: 59, milliseconds: 200);
    player.debugCrossfadeTick(main.position_);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(tail.playing, isTrue);

    await player.pause();
    expect(tail.playing, isFalse);
  });

  test('the last song in the queue is not crossfaded', () async {
    final main = _FakePlayer();
    final tail = _FakePlayer();
    final player = PlayerService(
      LibraryService(),
      player: main,
      tailPlayerFactory: () => tail,
    );
    await player.setCrossfadeSeconds(1);
    final only = _streamSong('aaaaaaaaaaa');
    await player.playSong(only, queue: [only]);
    main.position_ = const Duration(seconds: 59, milliseconds: 200);
    player.debugCrossfadeTick(main.position_);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(tail.loaded, isEmpty);
  });

  group('with shuffle on', () {
    Future<(_FakePlayer, _FakePlayer, PlayerService)> playShuffled(
      List<String> ids,
    ) async {
      final main = _FakePlayer();
      final tail = _FakePlayer();
      final player = PlayerService(
        LibraryService(),
        player: main,
        tailPlayerFactory: () => tail,
      );
      await player.setLoudnessNormalization(false);
      await player.setCrossfadeSeconds(1);
      final songs = [for (final id in ids) _streamSong(id)];
      player.toggleShuffle();
      await player.playSong(songs.first, queue: songs);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      return (main, tail, player);
    }

    test('the fade moves to a song that is ready, never one still to download',
        () async {
      for (var run = 0; run < 5; run++) {
        final (main, tail, player) = await playShuffled(
          ['aaaaaaaaaaa', 'ccccccccccc', 'bbbbbbbbbbb', 'ddddddddddd'],
        );
        main.position_ = const Duration(seconds: 59, milliseconds: 200);
        player.debugCrossfadeTick(main.position_);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(tail.loaded, ['aaaaaaaaaaa.m4a']);
        expect(player.currentSong?.id, 'stream_bbbbbbbbbbb');
      }
    });

    test('when nothing is ready the song plays out without a fade', () async {
      final (main, tail, player) =
          await playShuffled(['aaaaaaaaaaa', 'ccccccccccc']);
      main.position_ = const Duration(seconds: 59, milliseconds: 200);
      player.debugCrossfadeTick(main.position_);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tail.loaded, isEmpty);
      expect(player.currentSong?.id, 'stream_aaaaaaaaaaa');
    });
  });

  group('silence skipping', () {
    // Music from 2 s to 55 s of a one-minute file.
    const span = LoudnessAnalysis(
      lufs: -14,
      musicStart: 2,
      musicEnd: 55,
      length: 60,
    );
    setUp(() {
      LoudnessService.resetForTesting();
      LoudnessService.setSpanForTesting('aaaaaaaaaaa', span);
    });
    tearDown(LoudnessService.resetForTesting);

    test('a silent intro is skipped, keeping a moment of lead-in', () async {
      final (main, _, _) = await playFirst(crossfadeSeconds: 0);
      expect(main.position_, const Duration(milliseconds: 1700));
    });

    test('a silent outro moves on to the next song', () async {
      final (main, tail, player) = await playFirst(crossfadeSeconds: 0);
      main.position_ = const Duration(seconds: 55, milliseconds: 100);
      player.debugCrossfadeTick(main.position_);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.currentSong?.id, 'stream_aaaaaaaaaaa',
          reason: 'the music (plus a short pad) is not over yet');

      main.position_ = const Duration(seconds: 55, milliseconds: 400);
      player.debugCrossfadeTick(main.position_);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.currentSong?.id, 'stream_bbbbbbbbbbb');
      expect(tail.loaded, isEmpty);
    });

    test('a crossfade ends where the music does, not at the end of the file',
        () async {
      final (main, tail, player) = await playFirst(crossfadeSeconds: 1);
      main.position_ = const Duration(seconds: 54, milliseconds: 600);
      player.debugCrossfadeTick(main.position_);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tail.loaded, ['aaaaaaaaaaa.m4a']);
      expect(player.currentSong?.id, 'stream_bbbbbbbbbbb');
    });

    test('a span from a different file length is ignored', () async {
      LoudnessService.setSpanForTesting(
        'aaaaaaaaaaa',
        const LoudnessAnalysis(lufs: -14, musicStart: 0, musicEnd: 55, length: 1200),
      );
      final (main, _, player) = await playFirst(crossfadeSeconds: 0);
      main.position_ = const Duration(seconds: 56);
      player.debugCrossfadeTick(main.position_);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.currentSong?.id, 'stream_aaaaaaaaaaa');
    });
  });
}
