import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:peerm_app/services/pear_audio_handler.dart';
import 'package:peerm_app/services/player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PearAudioHandler handler;

  setUp(() {
    handler = PearAudioHandler();
  });

  group('Android 13+ Media Notification Contract', () {
    test('controls adhere strictly to Android 13+ platform requirements', () {
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

      // Slots 1, 2, 3 must be custom transport controls for direct action dispatch
      expect(state.controls[1].androidIcon, contains('drawable/pear_previous'));
      expect(state.controls[2].androidIcon, contains('drawable/pear_play'));
      expect(state.controls[3].androidIcon, contains('drawable/pear_next'));

      // Compact indices must map to Previous (1), Play/Pause (2), Next (3)
      expect(state.androidCompactActionIndices, equals(const [1, 2, 3]));

      // Slots 0 and 4 are custom controls for shuffle and repeat
      expect(state.controls[0].androidIcon, contains('drawable/pear_shuffle'));
      expect(state.controls[4].androidIcon, contains('drawable/pear_repeat'));
    });

    test('playing state toggles play and pause cleanly on slot 2', () {
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

    test('optimistic state transitions in play() and pause() retain custom controls', () async {
      handler.updateState(
        playing: false,
        processingState: ProcessingState.ready,
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        speed: 1.0,
        loopMode: LoopSetting.off,
        shuffle: false,
      );

      await handler.play();
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.controls[2].androidIcon, contains('drawable/pear_pause'));
      expect(handler.playbackState.value.controls[1].androidIcon, contains('drawable/pear_previous'));
      expect(handler.playbackState.value.controls[3].androidIcon, contains('drawable/pear_next'));

      await handler.pause();
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.controls[2].androidIcon, contains('drawable/pear_play'));
      expect(handler.playbackState.value.controls[1].androidIcon, contains('drawable/pear_previous'));
      expect(handler.playbackState.value.controls[3].androidIcon, contains('drawable/pear_next'));
    });

    test('customAction peerm_play and peerm_pause update state with custom controls', () async {
      handler.updateState(
        playing: false,
        processingState: ProcessingState.ready,
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        speed: 1.0,
        loopMode: LoopSetting.off,
        shuffle: false,
      );

      await handler.customAction('peerm_play');
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.controls[2].androidIcon, contains('drawable/pear_pause'));

      await handler.customAction('peerm_pause');
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.controls[2].androidIcon, contains('drawable/pear_play'));
    });

    test('systemActions contains all required media transport actions', () {
      handler.updateState(
        playing: true,
        processingState: ProcessingState.ready,
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        speed: 1.0,
        loopMode: LoopSetting.off,
        shuffle: false,
      );

      final actions = handler.playbackState.value.systemActions;
      expect(actions.contains(MediaAction.play), isTrue);
      expect(actions.contains(MediaAction.pause), isTrue);
      expect(actions.contains(MediaAction.skipToPrevious), isTrue);
      expect(actions.contains(MediaAction.skipToNext), isTrue);
      expect(actions.contains(MediaAction.seek), isTrue);
    });
  });
}
