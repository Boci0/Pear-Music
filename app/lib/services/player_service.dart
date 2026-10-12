import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../models/song.dart';
import 'artwork_palette.dart';
import 'artwork_service.dart';
import 'debug_log.dart';
import 'growing_file_audio_source.dart';
import 'history_service.dart';
import 'identity_service.dart';
import 'library_service.dart';
import 'live_hls_proxy.dart';
import 'loudness_service.dart';
import 'lyrics_service.dart';
import 'pear_audio_handler.dart';
import 'position_thinning.dart';
import 'recommendation_service.dart';
import 'session_diagnostics.dart';
import 'sleep_timer.dart';
import 'stream_cache_manager.dart';

part 'player_service/playback.dart';

part 'player_service/preload.dart';

part 'player_service/queue_edit.dart';

part 'player_service/recommendations.dart';

part 'player_service/live.dart';

part 'player_service/crossfade.dart';

/// How the queue advances when a track ends or the user skips.
enum LoopSetting { off, all, one }

/// Route through which the active song is being served.
enum StreamRouteType {
  cached, // Local disk cache (0ms instant)
  direct, // Primary Innertube direct stream
  fallback, // Secondary Piped / yt-dlp fallback
  local, // Local file
}

/// A playback failure on the current track. The track stays loaded so the
/// play button retries it, and [label] explains the failure where the
/// player UI already shows status text.
class PlaybackError {
  final Song song;

  /// Short line for the mini player / transport row.
  final String label;

  /// Full sentence for the app message feed (snack bar).
  final String message;

  /// Stream failure classification, when the failure came from a fetch.
  final StreamFetchFailureKind? kind;

  const PlaybackError({
    required this.song,
    required this.label,
    required this.message,
    this.kind,
  });
}

/// Audio playback using just_audio (ExoPlayer on Android, media_kit/mpv on
/// Windows). `JustAudioMediaKit.ensureInitialized()` must be called once in
/// `main()` before the first `AudioPlayer` is created.
///
/// The queue is owned in Dart: only ONE source is loaded at a time and
/// [next]/[previous] load the next song explicitly. This is reliable across
/// backends (multi-source playlists don't advance on media_kit: the cause of
/// "it just loops on 1 song") and gives us loop + shuffle for free. Each source
/// carries a [MediaItem] tag so the `audio_service` handler renders the
/// notification (play/pause, next/previous, repeat, shuffle).
class PlayerService extends ChangeNotifier with
        _PlayerCrossfade,
        _PlayerLive,
        _PlayerRecommendations,
        _PlayerPreload,
        _PlayerQueueEdit,
        _PlayerPlayback {
  @override
  final LibraryService library;
  @override
  final IdentityService? identity;

  /// Optional play log. Every track that starts playing is recorded here.
  @override
  final HistoryService? history;
  @override
  late final AudioPlayer _player;
  bool _loudnessNormalization = true;
  @override
  final math.Random _random = math.Random();

  @override
  Song? currentSong;
  static const int maxRecommendationsPerAppend = 10;

  @override
  List<Song> _queue = [];
  @override
  int _queueIndex = -1;
  @override
  String? queueSourceId; // 'library' | 'favorites' | 'search' | 'playlist:<id>' | 'radio'
  @override
  String? queueTitle;
  @override
  LoopSetting _loopMode = LoopSetting.off;
  @override
  bool _shuffle = false;
  @override
  final Set<String> _shufflePlayedSongIds = {};
  @override
  bool _autoplay = false;
  @override
  final Set<String> _lockedSongIds = {};

  /// Songs the app added to the queue itself (radio and autoplay
  /// recommendations). Only these may be swapped by the auto reroll: a song
  /// the listener queued, such as a playlist's next song, never is.
  @override
  final Set<String> _autoAddedSongIds = {};
  @override
  bool _autoRerollSeed = false;
  @override
  Timer? _autoRerollDebounceTimer;
  @override
  String? _lastAutoRerolledSongId;
  @override
  bool _isRerolling = false;
  bool get isRerolling => _isRerolling;
  @override
  Timer? _saveVolumeDebounceTimer;

  @override
  String? _continuationToken;
  @override
  bool _isLoadingRecommendations = false;
  @override
  DateTime _lastInteraction = DateTime.now();

  @visibleForTesting
  DateTime get debugLastInteraction => _lastInteraction;
  @visibleForTesting
  set debugLastInteraction(DateTime value) => _lastInteraction = value;
  @override
  bool _isManuallyPaused = false;
  @override
  bool _isAdvancing = false;
  @override
  bool _isLoadingTrack = false;
  @override
  bool _pendingNaturalAdvance = false;
  @override
  bool _isBufferingNext = false; // true while resolving next track's URL
  @override
  String? _bufferingVideoId;    // which track is being resolved
  @override
  int _consecutiveStreamFailures = 0;
  @override
  bool _isPreloadingUpcoming = false;
  @override
  PlaybackError? _playbackError;

  /// User-facing playback messages (wired to the app's snackbar feed).
  final StreamController<String> _userMessages =
      StreamController<String>.broadcast();

  @override
  late final SleepTimer _sleep = SleepTimer(onExpire: _triggerSleepTimerStop);
  @override
  double _speed = 1.0;
  double get speed => _speed;

  int _tracksPlayedSinceCompaction = 0;

  @override
  void _maybeCompactMemory() {
    _tracksPlayedSinceCompaction++;
    if (_tracksPlayedSinceCompaction >= 8) {
      _tracksPlayedSinceCompaction = 0;
      ArtworkPalette.compactMemory();
      LyricsService.compactMemory();
      PaintingBinding.instance.imageCache.clearLiveImages();
    }
  }

  final List<StreamSubscription> _subs = [];
  @override
  final PearAudioHandler? audioHandler;

  /// The still-downloading file the current track plays from (Android), kept
  /// so its file handle can be released when playback moves on.
  @override
  GrowingFileAudioSource? _growingSource;

  PlayerService(this.library,
      {this.identity,
      this.audioHandler,
      AudioPlayer? player,
      this.history,
      AudioPlayer Function()? tailPlayerFactory})
      : _tailPlayerFactory = tailPlayerFactory ?? _defaultTailPlayer {
    // Request headers (needed when streaming a resolved link before it is
    // cached) go straight to the engine: media_kit and ExoPlayer both accept
    // them, so just_audio's local proxy stays out of the audio path.
    _player = player ?? AudioPlayer(useProxyForRequestHeaders: false);
    if (identity != null) {
      _autoRerollSeed = identity!.autoRerollSeed;
      _autoplay = identity!.autoplay;
      _crossfadeSeconds = identity!.crossfadeSeconds;
      _speed = identity!.playbackSpeed;
    }
    if ((_speed - 1.0).abs() > 0.01) {
      unawaited(_player.setSpeed(_speed));
    }
    _initAudioHandler();
  }

  /// Behind this many seconds counts as live: a stream opened at the edge
  /// already sits [LiveHlsProxy.defaultLead] seconds back, plus the player's
  /// own buffer.
  static const double liveCloseEnough = 15;

  /// A pause longer than this reopens the stream where it was left instead of
  /// resuming from the relay's buffer (a minute of audio; the rest is gone).
  static const Duration _liveReopenAfter = Duration(seconds: 20);

  @override
  StreamRouteType _currentRouteType = StreamRouteType.local;
  StreamRouteType get currentRouteType => _currentRouteType;
  @override
  int _lastTrackLoadMs = 0;
  int get lastTrackLoadMs => _lastTrackLoadMs;

  @override
  File? _currentLoadedFile;
  @override
  int? _currentLoadedFileSize;
  @override
  String? _currentLoadedFormat;

  File? get currentLoadedFile => _currentLoadedFile;
  int? get currentLoadedFileSize => _currentLoadedFileSize;
  String? get currentLoadedFormat => _currentLoadedFormat;

  /// Inspects disk storage to ensure current loaded file metadata is resolved.
  Future<File?> resolveCurrentLoadedFile() async {
    if (_currentLoadedFile != null && await _currentLoadedFile!.exists()) {
      return _currentLoadedFile;
    }
    if (currentSong == null) return null;
    if (currentSong!.sourceDeviceId == 'stream') {
      final videoId = RecommendationService.extractVideoId(currentSong!.id) ??
          currentSong!.id.replaceFirst('stream_', '');
      final inspected = await StreamCacheManager.inspectTrackCache(videoId);
      if (inspected.isCached && inspected.filePath != null) {
        final changed = _currentLoadedFile?.path != inspected.filePath;
        _currentLoadedFile = File(inspected.filePath!);
        _currentLoadedFileSize = inspected.fileSize;
        _currentLoadedFormat = inspected.ext;
        if (changed) notifyListeners();
        return _currentLoadedFile;
      }
    } else {
      final file = library.songFile(currentSong!);
      if (await file.exists()) {
        final changed = _currentLoadedFile?.path != file.path;
        _currentLoadedFile = file;
        _currentLoadedFileSize = await file.length();
        _currentLoadedFormat = p.extension(file.path).replaceFirst('.', '');
        if (changed) notifyListeners();
        return file;
      }
    }
    return null;
  }

  Song? get song => currentSong;
  Duration? get position => _player.position;
  Duration? get duration => _player.duration;
  @override
  bool get playing =>
      !_isManuallyPaused && _player.playing && _player.processingState != ProcessingState.completed;
  @override
  double _userVolume = 0.75;
  double get volume => _userVolume;

  /// Volume changes ride their own notifier instead of [notifyListeners]:
  /// dragging the slider fires many updates a second, and a player-wide
  /// broadcast rebuilt the whole Now Playing pane on each one.
  @override
  final ValueNotifier<double> volumeNotifier = ValueNotifier<double>(0.75);

  /// Loudness normalisation multiplier for the current song (1.0 until it
  /// has been measured, see [LoudnessService]).
  @override
  double _songGain = 1.0;

  /// What the player's volume should be: the user's volume with the current
  /// song levelled. A lift for a quiet song only goes as far as full volume.
  @override
  double get _effectiveVolume =>
      (_userVolume * _mixerGain(_loudnessNormalization ? _songGain : 1.0))
          .clamp(0.0, 1.0);

  /// True when the engine applies volume on mpv's cubic scale (media_kit on
  /// Windows and Linux): the sound there is scaled by volume^3, not volume.
  @visibleForTesting
  static bool? debugCubicVolumeOverride;
  static bool get _cubicVolume =>
      debugCubicVolumeOverride ??
      (!kIsWeb && (Platform.isWindows || Platform.isLinux));

  /// The volume factor that scales the sound itself by [amplitude]. Song
  /// levels and crossfade curves are amplitudes; the user's own volume is
  /// not converted, so the slider keeps the feel it has on each platform.
  static double _mixerGain(double amplitude) {
    if (amplitude <= 0) return 0.0;
    return _cubicVolume ? math.pow(amplitude, 1 / 3).toDouble() : amplitude;
  }
  final ValueNotifier<Duration?> scrubbingPositionNotifier =
      ValueNotifier<Duration?>(null);
  Duration? get scrubbingPosition => scrubbingPositionNotifier.value;

  void setScrubbingPosition(Duration? position) {
    if (scrubbingPositionNotifier.value != position) {
      scrubbingPositionNotifier.value = position;
    }
  }

  bool get hasLoaded => currentSong != null;
  bool get loudnessNormalization => _loudnessNormalization;
  bool get isLoadingTrack => _isLoadingTrack;
  bool get isAdvancing => _isAdvancing;
  bool get isBufferingNext => _isBufferingNext;
  bool get isLoadingRecommendations => _isLoadingRecommendations;
  bool get isBuffering => _isLoadingTrack || _isBufferingNext;
  String? get bufferingVideoId => _bufferingVideoId;

  @visibleForTesting
  void setBufferingForTesting(bool buffering) {
    _isLoadingTrack = buffering;
    notifyListeners();
  }

  bool get isPreloadingUpcoming => _isPreloadingUpcoming;

  /// The failure that stopped the current track, or null while playback is
  /// healthy. Cleared as soon as a new load starts.
  PlaybackError? get playbackError => _playbackError;

  /// User-facing playback messages, consumed by the app's snackbar feed.
  Stream<String> get userMessages => _userMessages.stream;

  @override
  void _notifyUser(String message) {
    if (!_userMessages.isClosed) _userMessages.add(message);
  }

  @override
  void _setPlaybackError(PlaybackError error) {
    _playbackError = error;
    notifyListeners();
  }

  /// Clears the error banner. [notify] is false when the caller is already
  /// about to notify (for example when a new load starts).
  @override
  void clearPlaybackError({bool notify = true}) {
    if (_playbackError == null) return;
    _playbackError = null;
    if (notify) notifyListeners();
  }

  /// Builds the user-facing explanation for a failed stream fetch. YouTube
  /// blocking a request (HTTP 403) is usually temporary and must offer a
  /// retry instead of looking like the song is broken.
  static PlaybackError describeStreamFailure(
    StreamFetchFailure? failure,
    Song song,
  ) {
    switch (failure?.kind) {
      case StreamFetchFailureKind.blocked:
        return PlaybackError(
          song: song,
          kind: StreamFetchFailureKind.blocked,
          label: 'YouTube blocked this request. Tap play to retry.',
          message: 'Couldn\'t play "${song.title}": YouTube refused the '
              'request (blocked or bot check). This is usually temporary, '
              'tap play to retry.',
        );
      case StreamFetchFailureKind.network:
        return PlaybackError(
          song: song,
          kind: StreamFetchFailureKind.network,
          label: 'Network problem. Tap play to retry.',
          message: 'Couldn\'t play "${song.title}": the network dropped while '
              'fetching the audio. Tap play to retry.',
        );
      case StreamFetchFailureKind.engine:
        return PlaybackError(
          song: song,
          kind: StreamFetchFailureKind.engine,
          label: 'yt-dlp is missing on this device.',
          message: 'Couldn\'t play "${song.title}": yt-dlp is not installed '
              'on this device. On the PC install it with: winget install '
              'yt-dlp.yt-dlp (the phone has it built in).',
        );
      case StreamFetchFailureKind.runtime:
        return PlaybackError(
          song: song,
          kind: StreamFetchFailureKind.runtime,
          label: 'yt-dlp needs Deno to play this. See Settings.',
          message: 'Couldn\'t play "${song.title}": YouTube now needs a '
              'JavaScript runtime for this video and none is installed. '
              'Install Deno with: winget install DenoLand.Deno, then tap '
              'play to retry. Settings > Audio engine shows its status.',
        );
      case StreamFetchFailureKind.outdated:
        final onPhone = !kIsWeb && Platform.isAndroid;
        return PlaybackError(
          song: song,
          kind: StreamFetchFailureKind.outdated,
          label: onPhone
              ? 'The audio engine is out of date. Update Pear Music.'
              : 'yt-dlp is out of date. Tap play to retry.',
          message: onPhone
              ? 'Couldn\'t play "${song.title}": the built-in audio engine no '
                  'longer understands YouTube. Updating Pear Music brings a '
                  'newer one.'
              : 'Couldn\'t play "${song.title}": yt-dlp no longer understands '
                  'YouTube. The app is checking for a newer signed copy. If '
                  'that does not fix it, open Settings > Audio engine to '
                  'update, import a bundle, or choose your own yt-dlp.',
        );
      case StreamFetchFailureKind.unavailable:
        return PlaybackError(
          song: song,
          kind: StreamFetchFailureKind.unavailable,
          label: 'This video is unavailable on YouTube.',
          message: '"${song.title}" is unavailable on YouTube and was '
              'skipped.',
        );
      case StreamFetchFailureKind.unknown:
      case null:
        return PlaybackError(
          song: song,
          kind: failure?.kind,
          label: 'Couldn\'t load this track. Tap play to retry.',
          message: 'Couldn\'t play "${song.title}". Tap play to retry.',
        );
    }
  }


  bool get hasNextTrack => _queueIndex >= 0 && _queueIndex + 1 < _queue.length;

  bool get isNextTrackReady {
    if (!hasNextTrack) return true;
    final nextSong = _queue[_queueIndex + 1];
    if (nextSong.sourceDeviceId != 'stream') return true;
    return _isReadyToStart(nextSong);
  }

  /// The Android audio session ID associated with playback, or null on other platforms.
  int? get androidAudioSessionId => _player.androidAudioSessionId;

  /// Stream of Android audio session ID changes.
  Stream<int?> get androidAudioSessionIdStream => _player.androidAudioSessionIdStream;

  bool get isSleepTimerActive => _sleep.isActive;
  Duration? get sleepTimerRemaining => _sleep.remaining;
  bool get sleepTimerEndOfSong => _sleep.endOfSong;
  bool get sleepTimerEndOfQueue => _sleep.endOfQueue;

  List<Song> get queue => List.unmodifiable(_queue);
  int get queueIndex {
    _syncQueueIndexWithCurrentSong();
    return _queueIndex;
  }

  /// Synchronizes [_queueIndex] to the exact index of [currentSong] in [_queue].
  /// If the current song cannot be found in the queue, retains the existing valid index
  /// or defaults to -1 if empty.
  @override
  void _syncQueueIndexWithCurrentSong() {
    if (currentSong != null && _queue.isNotEmpty) {
      if (_queueIndex >= 0 &&
          _queueIndex < _queue.length &&
          _queue[_queueIndex].id == currentSong!.id) {
        return;
      }
      final idx = _queue.indexWhere((s) => s.id == currentSong!.id);
      if (idx >= 0) {
        _queueIndex = idx;
        return;
      }
    }
    if (_queue.isEmpty) {
      _queueIndex = -1;
    }
  }
  LoopSetting get loopMode => _loopMode;
  bool get shuffle => _shuffle;
  bool get autoplay => _autoplay;
  Set<String> get lockedSongIds => Set.unmodifiable(_lockedSongIds);

  bool isSongLocked(String songId) => _lockedSongIds.contains(songId);

  void toggleSongLock(String songId) {
    if (_lockedSongIds.contains(songId)) {
      _lockedSongIds.remove(songId);
    } else {
      _lockedSongIds.add(songId);
    }
    notifyListeners();
  }

  bool get autoRerollSeed => _autoRerollSeed;

  /// Whether the automatic reroll may swap the next song: only one the app
  /// picked itself (a radio queue, or recommendations added once the
  /// listener's own queue ran out). A song the listener queued, such as a
  /// playlist's next song, is never swapped.
  @override
  bool get _nextIsAutoRerollable {
    final i = _queueIndex + 1;
    if (i <= 0 || i >= _queue.length) return false;
    return queueSourceId == 'radio' || _autoAddedSongIds.contains(_queue[i].id);
  }

  void toggleAutoRerollSeed() {
    _autoRerollSeed = !_autoRerollSeed;
    identity?.setAutoRerollSeed(_autoRerollSeed);
    if (_autoRerollSeed && currentSong != null && _nextIsAutoRerollable) {
      _lastAutoRerolledSongId = currentSong!.id;
      unawaited(rerollNextTrackOnly());
    }
    notifyListeners();
  }

  void setAutoRerollSeed(bool value) {
    if (_autoRerollSeed == value) return;
    _autoRerollSeed = value;
    identity?.setAutoRerollSeed(_autoRerollSeed);
    if (_autoRerollSeed && currentSong != null && _nextIsAutoRerollable) {
      _lastAutoRerolledSongId = currentSong!.id;
      unawaited(rerollNextTrackOnly());
    }
    notifyListeners();
  }

  void setAutoplay(bool value) {
    if (_autoplay == value) return;
    _autoplay = value;
    identity?.setAutoplay(_autoplay);
    notifyListeners();
  }

  void setSleepTimer(
    Duration? duration, {
    bool endOfSong = false,
    bool endOfQueue = false,
  }) {
    _sleep.set(duration, endOfSong: endOfSong, endOfQueue: endOfQueue);
    _syncEngineLoop();
    notifyListeners();
  }

  @override
  void cancelSleepTimer() {
    _sleep.cancel();
    _syncEngineLoop();
    notifyListeners();
  }

  /// Repeat one runs on the engine's own single-file loop (mpv loop-file,
  /// ExoPlayer repeat one), which wraps around without a gap. Replaying from
  /// Dart after the completed event means a pause, a reload and a cold start,
  /// which is audible and briefly resets the seek bar. Every other mode stays
  /// in Dart, and so does repeat one while the end-of-song sleep timer is set,
  /// since that needs the song to actually end.
  @override
  LoopMode get _engineLoopMode =>
      _loopMode == LoopSetting.one && !_sleep.endOfSong
          ? LoopMode.one
          : LoopMode.off;

  @override
  void _syncEngineLoop() => unawaited(_player.setLoopMode(_engineLoopMode));

  Future<void> setSpeed(double speed) async {
    final clamped = speed.clamp(0.25, 3.0);
    if ((_speed - clamped).abs() < 0.01) return;
    _speed = clamped;
    try {
      await _player.setSpeed(_speed);
    } catch (e) {
      DebugLog.write('[player] setSpeed error: $e');
    }
    identity?.setPlaybackSpeed(_speed);
    notifyListeners();
  }

  @override
  int _volumeFadeToken = 0;

  @override
  Future<void> _fadeVolume(
    double targetVolume, {
    Duration duration = const Duration(milliseconds: 150),
  }) async {
    final fadeToken = ++_volumeFadeToken;
    final startVolume = _player.volume;
    if ((startVolume - targetVolume).abs() < 0.01) return;
    final steps = (duration.inMilliseconds / 25).round().clamp(6, 40);
    final stepDuration =
        Duration(milliseconds: math.max(1, (duration.inMilliseconds / steps).round()));
    final volumeDelta = (targetVolume - startVolume) / steps;
    try {
      for (var i = 1; i <= steps; i++) {
        await Future<void>.delayed(stepDuration);
        if (fadeToken != _volumeFadeToken) return;
        if (!_player.playing && targetVolume == 0) break;
        await _player.setVolume((startVolume + volumeDelta * i).clamp(0.0, 1.0));
      }
    } finally {
      if (fadeToken == _volumeFadeToken) {
        if (_player.playing || targetVolume == 0) {
          await _player.setVolume(targetVolume.clamp(0.0, 1.0));
        }
      }
    }
  }

  Future<void> _triggerSleepTimerStop() async {
    cancelSleepTimer();
    if (_player.playing && _userVolume > 0.05) {
      await _fadeVolume(0.0, duration: const Duration(seconds: 3));
    }
    await pause(smooth: false);
  }

  Future<void> setLoudnessNormalization(bool enabled) async {
    _loudnessNormalization = enabled;
    if (identity != null) {
      await identity!.setLoudnessNormalization(enabled);
    }
    final song = currentSong;
    if (enabled && song != null) _levelSong(song, _playRequestToken, null);
    if (_player.playing) {
      unawaited(_fadeVolume(_effectiveVolume, duration: const Duration(milliseconds: 600)));
    }
    notifyListeners();
  }

  /// Measures [song] once its audio file is complete (the loaded file, or
  /// [pendingDownload] for a song still streaming in) and then eases the
  /// volume to its level if it is still playing. Songs already measured are
  /// levelled straight away in [playSong].
  @override
  void _levelSong(Song song, int token, Future<File?>? pendingDownload) {
    // Measured even with normalisation off: the same pass finds the silence
    // that playback skips.
    if (!LoudnessService.isSupported || LoudnessService.isMeasured(song)) return;
    final loaded = _currentLoadedFile;
    unawaited(() async {
      final file = loaded ??
          await pendingDownload?.catchError((Object _) => null);
      if (file == null) return;
      final lufs = await LoudnessService.measure(song, file.path);
      if (lufs == null ||
          token != _playRequestToken ||
          currentSong?.id != song.id) {
        return;
      }
      final gain = LoudnessService.gainForLufs(lufs);
      // A song measured again for its silence keeps the level it had.
      if ((gain - _songGain).abs() < 0.001) {
        _levelNextSong();
        return;
      }
      _songGain = gain;
      if (_player.playing) {
        // Slow enough that the (usually small) correction from the typical
        // starting level is not heard as the song turning down.
        unawaited(_fadeVolume(_effectiveVolume, duration: const Duration(seconds: 6)));
      }
      _levelNextSong();
    }());
  }

  @override
  final AudioPlayer Function() _tailPlayerFactory;
  static AudioPlayer _defaultTailPlayer() => AudioPlayer(
        // The tail only finishes a song the main player already owns: it must
        // not take audio focus, react to interruptions or claim the session.
        handleInterruptions: false,
        handleAudioSessionActivation: false,
        androidApplyAudioAttributes: false,
        useProxyForRequestHeaders: false,
      );

  /// Measures the next song ahead of time when its file is already on disk,
  /// so it starts at the right level.
  @override
  void _levelNextSong() {
    if (!LoudnessService.isSupported) return;
    final i = _queueIndex + 1;
    if (i <= 0 || i >= _queue.length) return;
    final next = _queue[i];
    if (LoudnessService.isMeasured(next)) return;
    unawaited(() async {
      File? file;
      if (next.sourceDeviceId == 'stream') {
        final videoId = RecommendationService.extractVideoId(next.id) ??
            next.id.replaceFirst('stream_', '');
        file = await StreamCacheManager.getCachedFile(videoId);
      } else if (library.hasSongFile(next)) {
        file = library.songFile(next);
      }
      if (file != null) await LoudnessService.measure(next, file.path);
    }());
  }

  Future<void> init() async {
    _loudnessNormalization = identity?.loudnessNormalization ?? true;
    unawaited(LoudnessService.load());

    // Pre-render the default album art (if it isn't cached yet) so the first
    // play starts instantly and the notification already has artwork.
    ArtworkService.warmUp();
    unawaited(StreamCacheManager.warmUp());
    unawaited(_requestNotificationPermissionIfNeeded());

    // Loop modes are implemented in Dart (single-source loads), which is also
    // what fixes the "loops on 1 song" issue on backends that don't advance
    // playlists. The one exception is repeat one: see [_engineLoopMode].
    _userVolume = identity?.playbackVolume ?? 0.75;
    volumeNotifier.value = _userVolume;
    unawaited(_player.setVolume(_effectiveVolume));
    _syncEngineLoop();

    // NOTE: `positionStream` is deliberately NOT forwarded through
    // notifyListeners(). It fires many times per second while playing and
    // would rebuild every widget watching AppController (HomeShell keeps all
    // three tabs alive via IndexedStack) on every tick: the single biggest
    // cause of UI jank. Widgets that need live position subscribe to
    // [positionStream] directly with a StreamBuilder instead (see PlayerScreen
    // seek bar). We still notify on everything that changes rarely: duration,
    // play/pause state and processing state.
    _subs.add(_player.durationStream.listen((duration) {
      final song = currentSong;
      if (song != null) audioHandler?.updateSongDuration(song.id, duration);
      _publishNotificationState();
      notifyListeners();
    }));
    _subs.add(_player.playerStateStream.listen((state) {
      SessionDiagnostics.updatePlaybackState(state.playing);
      if (state.playing && _isLoadingTrack) {
        _isLoadingTrack = false;
      }
      if (state.playing) {
        _isManuallyPaused = false;
      }
      if (_isLive) {
        // A paused live stream falls further behind the edge each second.
        final since = _livePausedSince;
        if (!state.playing) {
          _livePausedSince ??= DateTime.now();
        } else if (since != null) {
          _liveBehind += DateTime.now().difference(since).inMilliseconds / 1000;
          _livePausedSince = null;
        }
      }
      _publishNotificationState();
      notifyListeners();
    }));
    _subs.add(_player.playbackEventStream.listen((event) {
      _publishNotificationState();
    }));
    _subs.add(positionStream.listen(_onPosition));
    // Auto-advance (loop / shuffle aware) when a track finishes.
    _subs.add(_player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && _queue.isNotEmpty) {
        if (_isLoadingTrack || _isAdvancing) {
          _pendingNaturalAdvance = true;
          DebugLog.write('[player] Completed event arrived while loading/advancing; flagged _pendingNaturalAdvance');
          return;
        }
        DebugLog.write('[player] Track completed naturally; advancing next');
        _onNaturalEnd();
      }
    }));
    _publishNotificationState();
  }

  /// What happens when a song finishes on its own (or reaches the silence
  /// after its music): sleep timers first, otherwise on to the next song.
  @override
  void _onNaturalEnd() {
    if (_sleep.endOfSong) {
      cancelSleepTimer();
      unawaited(pause(smooth: true));
    } else if (_sleep.endOfQueue &&
        (_queueIndex >= _queue.length - 1 || _queueIndex < 0)) {
      cancelSleepTimer();
      unawaited(pause(smooth: true));
    } else {
      unawaited(next());
    }
  }

  void _initAudioHandler() {
    final h = audioHandler;
    if (h == null) return;

    h.onPlay = () => resume();
    h.onPause = () => pause(smooth: false);
    h.onStop = () => stop();
    h.onSkipToNext = () => next(userAction: true);
    h.onSkipToPrevious = () => previous();
    h.onSeek = (pos) => seek(pos);
    h.onSetRepeatMode = (mode) async {
      _loopMode = switch (mode) {
        AudioServiceRepeatMode.one => LoopSetting.one,
        AudioServiceRepeatMode.all => LoopSetting.all,
        _ => LoopSetting.off,
      };
      _syncEngineLoop();
      _publishNotificationState();
      notifyListeners();
    };
    h.onSetShuffleMode = (mode) async {
      _shuffle = mode == AudioServiceShuffleMode.all;
      _shufflePlayedSongIds.clear();
      if (_shuffle && currentSong != null) {
        _shufflePlayedSongIds.add(currentSong!.id);
      }
      _publishNotificationState();
      notifyListeners();
    };
    h.onCustomAction = (name) async {
      switch (name) {
        case 'peerm_repeat':
          await toggleLoop();
          break;
        case 'peerm_shuffle':
          toggleShuffle();
          break;
        case 'peerm_play':
          await resume();
          break;
        case 'peerm_pause':
          await pause(smooth: false);
          break;
        case 'peerm_previous':
          await previous();
          break;
        case 'peerm_next':
          await next(userAction: true);
          break;
      }
    };
  }

  /// Live playback position, throttled to ~250 ms so the seek bar updates
  /// smoothly without rebuilding the whole player screen. Consume with a
  /// `StreamBuilder`, never with `notifyListeners()`.
  ///
  /// Created once and shared (it is a broadcast stream). Every
  /// `createPositionStream` call starts its own periodic timer and player
  /// event subscription that only stop when the player is disposed, not
  /// when listeners cancel, so building a fresh stream per read (widgets read
  /// this inside build) leaked a 4 Hz timer on every rebuild.
  late final Stream<Duration> positionStream = _player.createPositionStream(
    minPeriod: const Duration(milliseconds: 250),
    maxPeriod: const Duration(milliseconds: 250),
  );

  /// [positionStream] thinned to about four updates a second (seeks still at
  /// once), for read-outs that only show where the song is: the status bar
  /// time, the Now Playing pane's progress line and the mini player's fill.
  /// The engine also reports position on every playback event, about 15 times
  /// a second on desktop, and each report redraws the window; see
  /// [thinPositions]. Lyrics and the visualizer, which need fine timing, keep
  /// the full-rate [positionStream].
  late final Stream<Duration> uiPositionStream = thinPositions(positionStream);

  /// Live duration stream from underlying audio player.
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  int _playRequestToken = 0;

  /// How long opening a stream's direct link may take before falling back.
  static const Duration _earlyStreamOpenTimeout = Duration(seconds: 10);

  @override
  Future<void> stop() async {
    _silenceTail();
    _playRequestToken++;
    _preloadDebounceTimer?.cancel();
    _autoRerollDebounceTimer?.cancel();
    _autoRerollDebounceTimer = null;
    StreamCacheManager.cancelPreload();
    // A load cut short by the new token never reaches its own cleanup, so
    // its flags are reset here or play would stay blocked afterwards.
    if (_isLoadingTrack || _isBufferingNext) {
      StreamCacheManager.cancelActiveDownload();
    }
    _isLoadingTrack = false;
    _isBufferingNext = false;
    _bufferingVideoId = null;
    _isAdvancing = false;
    _pendingNaturalAdvance = false;
    final growing = _growingSource;
    _growingSource = null;
    if (growing != null) unawaited(growing.close());
    await _player.stop();
    // A live stream's relay would otherwise keep its port and client until
    // the next play; the stream is over, so is the relay.
    _isLive = false;
    LiveHlsProxy.stop();
    currentSong = null;
    _playbackError = null;
    _currentLoadedFile = null;
    _currentLoadedFileSize = null;
    _currentLoadedFormat = null;
    _queue = [];
    _queueIndex = -1;
    _shufflePlayedSongIds.clear();
    _lockedSongIds.clear();
    _autoAddedSongIds.clear();
    _isPreloadingUpcoming = false;
    _updateActiveQueueCacheProtection();
    audioHandler?.mediaItem.add(null);
    _publishNotificationState();
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    LiveHlsProxy.stop();
    _tailToken++;
    unawaited(_tailPlayer?.dispose());
    _tailPlayer = null;
    _playRequestToken++;
    unawaited(_growingSource?.close());
    _growingSource = null;
    _preloadDebounceTimer?.cancel();
    _autoRerollDebounceTimer?.cancel();
    _saveVolumeDebounceTimer?.cancel();
    _sleep.cancel();
    StreamCacheManager.cancelPreload();
    StreamCacheManager.cancelActiveDownload();
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    scrubbingPositionNotifier.dispose();
    _userMessages.close();
    audioHandler?.mediaItem.add(null);
    super.dispose();
  }
}

