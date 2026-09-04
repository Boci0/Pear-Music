import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import '../models/song.dart';
import 'player_service.dart';

/// Direct [AudioHandler] implementation connecting Android's MediaSession,
/// lockscreen, and notifications directly to [PlayerService].
class PearAudioHandler extends BaseAudioHandler with SeekHandler {
  Future<void> Function()? onPlay;
  Future<void> Function()? onPause;
  Future<void> Function()? onSkipToNext;
  Future<void> Function()? onSkipToPrevious;
  Future<void> Function(Duration)? onSeek;
  Future<void> Function(AudioServiceRepeatMode)? onSetRepeatMode;
  Future<void> Function(AudioServiceShuffleMode)? onSetShuffleMode;
  Future<void> Function(String name)? onCustomAction;

  bool _lastShuffle = false;
  LoopSetting _lastLoopMode = LoopSetting.off;

  static List<MediaControl> _buildControls({
    required bool playing,
    required bool shuffle,
    required LoopSetting loopMode,
  }) {
    return [
      _shuffleControl(shuffle),
      MediaControl.skipToPrevious,
      if (playing) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
      _repeatControl(loopMode),
    ];
  }

  @override
  Future<void> play() async {
    playbackState.add(playbackState.value.copyWith(
      playing: true,
      controls: _buildControls(
        playing: true,
        shuffle: _lastShuffle,
        loopMode: _lastLoopMode,
      ),
    ));
    if (onPlay != null) {
      await onPlay!();
    }
  }

  @override
  Future<void> pause() async {
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      controls: _buildControls(
        playing: false,
        shuffle: _lastShuffle,
        loopMode: _lastLoopMode,
      ),
    ));
    if (onPause != null) {
      await onPause!();
    }
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        if (playbackState.valueOrNull?.playing == true) {
          await pause();
        } else {
          await play();
        }
        break;
      case MediaButton.next:
        await skipToNext();
        break;
      case MediaButton.previous:
        await skipToPrevious();
        break;
    }
  }

  @override
  Future<void> skipToNext() async {
    if (onSkipToNext != null) {
      await onSkipToNext!();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (onSkipToPrevious != null) {
      await onSkipToPrevious!();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (onSeek != null) {
      await onSeek!(position);
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    if (onSetRepeatMode != null) {
      await onSetRepeatMode!(repeatMode);
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if (onSetShuffleMode != null) {
      await onSetShuffleMode!(shuffleMode);
    }
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'peerm_play':
        playbackState.add(playbackState.value.copyWith(
          playing: true,
          controls: _buildControls(
            playing: true,
            shuffle: _lastShuffle,
            loopMode: _lastLoopMode,
          ),
        ));
        break;
      case 'peerm_pause':
        playbackState.add(playbackState.value.copyWith(
          playing: false,
          controls: _buildControls(
            playing: false,
            shuffle: _lastShuffle,
            loopMode: _lastLoopMode,
          ),
        ));
        break;
    }
    if (onCustomAction != null) {
      await onCustomAction!(name);
      return;
    }
    await super.customAction(name, extras);
  }

  /// Updates current track metadata shown on lockscreen and media notification.
  void updateSongMediaItem(Song song, {Duration? duration, Uri? artUri}) {
    final prev = mediaItem.valueOrNull;
    final item = MediaItem(
      id: song.id,
      title: song.title,
      album: song.sourceDeviceId == 'stream' ? 'Pear Radio' : 'Local Music',
      duration: duration ?? (prev?.id == song.id ? prev?.duration : null),
      artUri: artUri ?? (prev?.id == song.id ? prev?.artUri : null),
    );
    mediaItem.add(item);
  }

  /// Synchronizes playback and notification transport state with [PlayerService].
  void updateState({
    required bool playing,
    required ProcessingState processingState,
    required Duration position,
    required Duration bufferedPosition,
    required double speed,
    required LoopSetting loopMode,
    required bool shuffle,
    int? queueIndex,
  }) {
    _lastShuffle = shuffle;
    _lastLoopMode = loopMode;

    final controls = _buildControls(
      playing: playing,
      shuffle: shuffle,
      loopMode: loopMode,
    );

    playbackState.add(PlaybackState(
      controls: controls,
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.playPause,
        MediaAction.stop,
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToPrevious,
        MediaAction.skipToNext,
        MediaAction.setRepeatMode,
        MediaAction.setShuffleMode,
      },
      androidCompactActionIndices: const [1, 2, 3],
      processingState: _mapProcessingState(processingState),
      playing: playing,
      updatePosition: position,
      bufferedPosition: bufferedPosition,
      speed: speed,
      repeatMode: _mapRepeatMode(loopMode),
      shuffleMode:
          shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      queueIndex: queueIndex,
    ));
  }

  static MediaControl _shuffleControl(bool shuffle) {
    return MediaControl.custom(
      androidIcon:
          shuffle ? 'drawable/pear_shuffle' : 'drawable/pear_shuffle_off',
      label: shuffle ? 'Shuffle: On' : 'Shuffle: Off',
      name: 'peerm_shuffle',
    );
  }

  static MediaControl _repeatControl(LoopSetting loopMode) {
    final icon = switch (loopMode) {
      LoopSetting.one => 'drawable/pear_repeat_one',
      LoopSetting.all => 'drawable/pear_repeat',
      LoopSetting.off => 'drawable/pear_repeat_off',
    };
    final label = switch (loopMode) {
      LoopSetting.one => 'Repeat: One',
      LoopSetting.all => 'Repeat: All',
      LoopSetting.off => 'Repeat: Off',
    };
    return MediaControl.custom(
      androidIcon: icon,
      label: label,
      name: 'peerm_repeat',
    );
  }

  static AudioProcessingState _mapProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  static AudioServiceRepeatMode _mapRepeatMode(LoopSetting mode) {
    switch (mode) {
      case LoopSetting.one:
        return AudioServiceRepeatMode.one;
      case LoopSetting.all:
        return AudioServiceRepeatMode.all;
      case LoopSetting.off:
        return AudioServiceRepeatMode.none;
    }
  }
}
