import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/pear_audio_handler.dart';
import 'package:peerm_app/services/player_service.dart';

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
}
