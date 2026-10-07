import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/loudness_meter.dart';
import 'package:peerm_app/services/loudness_service.dart';
import 'package:peerm_app/services/pear_audio_handler.dart';
import 'package:peerm_app/services/player_service.dart';

/// Behaves like just_audio on the media_kit backend at the end of a song:
/// `playing` stays true once the song completes, `play()` does nothing while
/// `playing` is true, and only a load takes the engine out of the completed
/// state (a seek or play within a file on disk does not).
class _EndOfSongPlayer extends AudioPlayer {
  _EndOfSongPlayer() : super(handleAudioSessionActivation: false);

  final _states = StreamController<ProcessingState>.broadcast();
  ProcessingState _state = ProcessingState.ready;
  bool _playing = true;

  /// Play requests that actually reached the engine.
  int playRequests = 0;

  void complete() {
    _state = ProcessingState.completed;
    _states.add(_state);
  }

  @override
  bool get playing => _playing;

  @override
  ProcessingState get processingState => _state;

  @override
  Stream<ProcessingState> get processingStateStream => _states.stream;

  @override
  Duration get position => Duration.zero;

  /// Positions the engine was asked to seek to.
  final List<Duration?> seeks = [];

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  Future<void> seek(Duration? position, {int? index}) async =>
      seeks.add(position);

  /// Sources loaded after the first one.
  int loads = 0;

  @override
  AudioSource? get audioSource => AudioSource.uri(Uri.file('/song.mp3'));

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    loads++;
    _state = ProcessingState.ready;
    _states.add(_state);
    return const Duration(minutes: 3);
  }

  @override
  Future<void> play() async {
    if (_playing) return;
    _playing = true;
    playRequests++;
  }

  @override
  Future<void> pause() async => _playing = false;

  @override
  Future<void> setVolume(double volume) async {}

  /// The loop mode last handed to the engine.
  LoopMode engineLoop = LoopMode.off;

  @override
  Future<void> setLoopMode(LoopMode mode) async => engineLoop = mode;
}

/// Locks in the loop/shuffle behaviour the user asked for: the repeat button
/// cycles no-loop -> whole-album -> one-song -> no-loop, and shuffle toggles.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryService library;
  late PearAudioHandler handler;
  late PlayerService player;

  setUp(() {
    library = LibraryService();
    handler = PearAudioHandler();
    player = PlayerService(library, audioHandler: handler);
  });

  test('toggleLoop cycles off -> all -> one -> off', () {
    expect(player.loopMode, LoopSetting.off);
    player.toggleLoop();
    expect(player.loopMode, LoopSetting.all, reason: 'first tap = whole album');
    player.toggleLoop();
    expect(player.loopMode, LoopSetting.one, reason: 'second tap = one song');
    player.toggleLoop();
    expect(player.loopMode, LoopSetting.off, reason: 'third tap = no loop');
  });

  test('toggleShuffle toggles on/off', () {
    expect(player.shuffle, isFalse);
    player.toggleShuffle();
    expect(player.shuffle, isTrue);
    player.toggleShuffle();
    expect(player.shuffle, isFalse);
  });

  test('notification customAction routes loop and shuffle correctly', () async {
    await player.init();
    expect(player.loopMode, LoopSetting.off);
    expect(player.shuffle, isFalse);

    await handler.customAction('peerm_repeat');
    expect(player.loopMode, LoopSetting.all);

    await handler.customAction('peerm_repeat');
    expect(player.loopMode, LoopSetting.one);

    await handler.customAction('peerm_repeat');
    expect(player.loopMode, LoopSetting.off);

    await handler.customAction('peerm_shuffle');
    expect(player.shuffle, isTrue);

    await handler.customAction('peerm_shuffle');
    expect(player.shuffle, isFalse);
  });

  test('playbackState provides 5 custom controls with direct action routing', () {
    handler.updateState(
      playing: false,
      processingState: ProcessingState.ready,
      position: Duration.zero,
      bufferedPosition: Duration.zero,
      speed: 1.0,
      loopMode: LoopSetting.off,
      shuffle: false,
    );

    final state = handler.playbackState.value;
    expect(state.controls.length, 5);
    expect(state.controls[1].androidIcon, contains('drawable/pear_previous'));
    expect(state.controls[2].androidIcon, contains('drawable/pear_play'));
    expect(state.controls[3].androidIcon, contains('drawable/pear_next'));
    expect(state.androidCompactActionIndices, const [1, 2, 3]);

    handler.updateState(
      playing: true,
      processingState: ProcessingState.ready,
      position: Duration.zero,
      bufferedPosition: Duration.zero,
      speed: 1.0,
      loopMode: LoopSetting.off,
      shuffle: false,
    );
    expect(handler.playbackState.value.controls[2].androidIcon, contains('drawable/pear_pause'));
  });

  test('repeat one loops on the engine unless the song has to end', () async {
    final engine = _EndOfSongPlayer();
    final looping = PlayerService(library, player: engine);
    await looping.init();
    expect(engine.engineLoop, LoopMode.off);

    looping.toggleLoop();
    expect(engine.engineLoop, LoopMode.off, reason: 'repeat all stays in Dart');
    looping.toggleLoop();
    expect(engine.engineLoop, LoopMode.one,
        reason: 'repeat one wraps on the engine, without a gap');

    looping.setSleepTimer(null, endOfSong: true);
    expect(engine.engineLoop, LoopMode.off,
        reason: 'the end-of-song sleep timer needs the song to end');
    looping.cancelSleepTimer();
    expect(engine.engineLoop, LoopMode.one);

    looping.toggleLoop();
    expect(engine.engineLoop, LoopMode.off);
  });

  test('loop one still replays the song if the engine reports an end',
      () async {
    final engine = _EndOfSongPlayer();
    final looping = PlayerService(library, player: engine);
    await looping.init();
    looping.updateQueue([
      Song(
        id: 's1',
        title: 'Song 1',
        fileName: 's1.mp3',
        size: 100,
        checksum: 'chk_s1',
        addedAt: DateTime(2026, 1, 1),
      ),
    ]);
    looping.toggleLoop();
    looping.toggleLoop();
    expect(looping.loopMode, LoopSetting.one);

    engine.complete();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(engine.playRequests, 1,
        reason: 'the replay must reach the engine, not be swallowed as a '
            'no-op play while just_audio still reports playing');
    expect(engine.loads, 1,
        reason: 'only a reload takes the engine out of the completed state');
    expect(engine.processingState, ProcessingState.ready);
    expect(looping.playing, isTrue,
        reason: 'the play button must show pause while the loop plays');
  });

  group('repeat one on the engine', () {
    final song = Song(
      id: 'stream_aaaaaaaaaaa',
      title: 'Song a',
      fileName: 'stream_aaaaaaaaaaa.m4a',
      size: 0,
      checksum: 'stream_aaaaaaaaaaa',
      sourceDeviceId: 'stream',
      addedAt: DateTime(2026, 1, 1),
    );

    setUp(() {
      LoudnessService.resetForTesting();
      // Music from 5 s to the end of a three-minute file.
      LoudnessService.setSpanForTesting(
        'aaaaaaaaaaa',
        const LoudnessAnalysis(
            lufs: -14, musicStart: 5, musicEnd: 180, length: 180),
      );
    });
    tearDown(LoudnessService.resetForTesting);

    Future<(_EndOfSongPlayer, PlayerService)> loopOne() async {
      final engine = _EndOfSongPlayer();
      final looping = PlayerService(library, player: engine);
      await looping.init();
      looping.currentSong = song;
      looping.toggleLoop();
      looping.toggleLoop();
      return (engine, looping);
    }

    test('a wrap to the start skips the silent intro again', () async {
      final (engine, looping) = await loopOne();
      looping.debugCrossfadeTick(const Duration(minutes: 2, seconds: 59));
      looping.debugCrossfadeTick(const Duration(milliseconds: 200));
      expect(engine.seeks, [const Duration(milliseconds: 4500)]);
    });

    test('playing on through the song never seeks', () async {
      final (engine, looping) = await loopOne();
      for (var s = 0; s < 180; s += 10) {
        looping.debugCrossfadeTick(Duration(seconds: s));
      }
      expect(engine.seeks, isEmpty);
    });

    test('a user seek back to the start is left alone', () async {
      final (engine, looping) = await loopOne();
      looping.debugCrossfadeTick(const Duration(minutes: 2, seconds: 59));
      await looping.seek(Duration.zero);
      looping.debugCrossfadeTick(const Duration(milliseconds: 200));
      expect(engine.seeks, [Duration.zero]);
    });
  });
}
