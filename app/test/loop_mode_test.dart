import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/pear_audio_handler.dart';
import 'package:peerm_app/services/player_service.dart';

/// Behaves like just_audio at the end of a song: `playing` stays true once
/// the song completes, `play()` does nothing while `playing` is true, and a
/// seek alone does not take the engine out of the completed state.
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

  @override
  Future<void> seek(Duration? position, {int? index}) async {}

  @override
  Future<void> play() async {
    if (_playing) return;
    _playing = true;
    playRequests++;
    if (_state == ProcessingState.completed) {
      _state = ProcessingState.ready;
      _states.add(_state);
    }
  }

  @override
  Future<void> pause() async => _playing = false;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setLoopMode(LoopMode mode) async {}
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

  test('loop one actually replays the song when it ends', () async {
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
    expect(engine.processingState, ProcessingState.ready);
    expect(looping.playing, isTrue,
        reason: 'the play button must show pause while the loop plays');
  });
}
