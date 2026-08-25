import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/song.dart';
import 'artwork_service.dart';
import 'identity_service.dart';
import 'library_service.dart';
import 'recommendation_service.dart';
import 'stream_cache_manager.dart';
import 'youtube_search_service.dart';

/// How the queue advances when a track ends or the user skips.
enum LoopSetting { off, all, one }

/// Audio playback using just_audio (ExoPlayer on Android, media_kit/mpv on
/// Windows). `JustAudioMediaKit.ensureInitialized()` must be called once in
/// `main()` before the first `AudioPlayer` is created.
///
/// The queue is owned in Dart: only ONE source is loaded at a time and
/// [next]/[previous] load the next song explicitly. This is reliable across
/// backends (multi-source playlists don't advance on media_kit: the cause of
/// "it just loops on 1 song") and gives us loop + shuffle for free. Each source
/// carries a [MediaItem] tag so `just_audio_background` renders the
/// notification (play/pause, next/previous, repeat, shuffle).
class PlayerService extends ChangeNotifier {
  final LibraryService library;
  final IdentityService? identity;
  late final AudioPlayer _player;
  AndroidLoudnessEnhancer? _loudnessEnhancer;
  bool _loudnessNormalization = true;
  final math.Random _random = math.Random();

  Song? currentSong;
  List<Song> _queue = [];
  int _queueIndex = -1;
  String? queueSourceId; // 'library' | 'favorites' | 'search' | 'playlist:<id>' | 'radio'
  String? queueTitle;
  LoopSetting _loopMode = LoopSetting.off;
  bool _shuffle = false;
  bool _autoplay = true;

  String? _continuationToken;
  bool _isLoadingRecommendations = false;
  DateTime _lastInteraction = DateTime.now();

  Timer? _sleepTimer;
  DateTime? _sleepTimerEndTime;
  bool _sleepTimerEndOfSong = false;

  final List<StreamSubscription> _subs = [];

  PlayerService(this.library, {this.identity}) {
    if (Platform.isAndroid) {
      _loudnessEnhancer = AndroidLoudnessEnhancer();
      final pipeline = AudioPipeline(androidAudioEffects: [_loudnessEnhancer!]);
      _player = AudioPlayer(audioPipeline: pipeline);
    } else {
      _player = AudioPlayer();
    }
  }

  Song? get song => currentSong;
  Duration? get position => _player.position;
  Duration? get duration => _player.duration;
  bool get playing => _player.playing;
  double get volume => _player.volume;
  bool get hasLoaded => currentSong != null;
  bool get loudnessNormalization => _loudnessNormalization;

  bool get isSleepTimerActive => _sleepTimer != null || _sleepTimerEndOfSong;
  Duration? get sleepTimerRemaining => _sleepTimerEndTime != null
      ? _sleepTimerEndTime!.difference(DateTime.now())
      : null;
  bool get sleepTimerEndOfSong => _sleepTimerEndOfSong;

  List<Song> get queue => List.unmodifiable(_queue);
  int get queueIndex => _queueIndex;
  LoopSetting get loopMode => _loopMode;
  bool get shuffle => _shuffle;
  bool get autoplay => _autoplay;

  void setAutoplay(bool value) {
    if (_autoplay == value) return;
    _autoplay = value;
    notifyListeners();
  }

  void setSleepTimer(Duration? duration, {bool endOfSong = false}) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndTime = null;
    _sleepTimerEndOfSong = endOfSong;

    if (endOfSong) {
      notifyListeners();
      return;
    }

    if (duration != null && duration > Duration.zero) {
      _sleepTimerEndTime = DateTime.now().add(duration);
      _sleepTimer = Timer(duration, () async {
        await _triggerSleepTimerStop();
      });
    }
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndTime = null;
    _sleepTimerEndOfSong = false;
    notifyListeners();
  }

  Future<void> _fadeVolume(
    double targetVolume, {
    Duration duration = const Duration(milliseconds: 100),
  }) async {
    final startVolume = _player.volume;
    if ((startVolume - targetVolume).abs() < 0.01) return;
    const steps = 6;
    final stepDuration =
        Duration(milliseconds: (duration.inMilliseconds / steps).round());
    final volumeDelta = (targetVolume - startVolume) / steps;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(stepDuration);
      if (!_player.playing && targetVolume == 0) break;
      await _player.setVolume((startVolume + volumeDelta * i).clamp(0.0, 1.0));
    }
  }

  Future<void> _triggerSleepTimerStop() async {
    final originalVol = _player.volume;
    if (_player.playing && originalVol > 0.05) {
      await _fadeVolume(0.0, duration: const Duration(seconds: 3));
      await _player.pause();
      await _player.setVolume(originalVol);
    } else {
      await _player.pause();
    }
    cancelSleepTimer();
  }

  Future<void> setLoudnessNormalization(bool enabled) async {
    _loudnessNormalization = enabled;
    if (identity != null) {
      await identity!.setLoudnessNormalization(enabled);
    }
    if (Platform.isAndroid && _loudnessEnhancer != null) {
      try {
        await _loudnessEnhancer!.setEnabled(enabled);
        if (enabled) {
          await _loudnessEnhancer!.setTargetGain(2.0);
        }
      } catch (e) {
        debugPrint('[player] loudness enhancer error: $e');
      }
    }
    notifyListeners();
  }

  Future<void> init() async {
    _loudnessNormalization = identity?.loudnessNormalization ?? true;
    if (Platform.isAndroid && _loudnessEnhancer != null) {
      try {
        await _loudnessEnhancer!.setEnabled(_loudnessNormalization);
        if (_loudnessNormalization) {
          await _loudnessEnhancer!.setTargetGain(2.0);
        }
      } catch (_) {}
    }

    // Pre-render the default album art (if it isn't cached yet) so the first
    // play starts instantly and the notification already has artwork.
    ArtworkService.warmUp();

    // Never let the underlying player loop by itself: loop modes are
    // implemented in Dart (single-source loads). This is also what fixes the
    // "loops on 1 song" issue on backends that don't advance playlists.
    unawaited(_player.setLoopMode(LoopMode.off));

    // NOTE: `positionStream` is deliberately NOT forwarded through
    // notifyListeners(). It fires many times per second while playing and
    // would rebuild every widget watching AppController (HomeShell keeps all
    // three tabs alive via IndexedStack) on every tick: the single biggest
    // cause of UI jank. Widgets that need live position subscribe to
    // [positionStream] directly with a StreamBuilder instead (see PlayerScreen
    // seek bar). We still notify on everything that changes rarely: duration,
    // play/pause state and processing state.
    _subs.add(_player.durationStream.listen((_) => notifyListeners()));
    _subs.add(_player.playerStateStream.listen((_) => notifyListeners()));
    // Auto-advance (loop / shuffle aware) when a track finishes.
    _subs.add(_player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && _queue.isNotEmpty) {
        if (_sleepTimerEndOfSong) {
          _sleepTimerEndOfSong = false;
          unawaited(pause(smooth: true));
        } else {
          unawaited(next());
        }
      }
    }));

    // Route the media notification's transport buttons to our own queue so
    // next / previous / repeat / shuffle work with the Dart-managed queue.
    JustAudioBackground.onSkipToNext = () => unawaited(next());
    JustAudioBackground.onSkipToPrevious = () => unawaited(previous());
    JustAudioBackground.onSetRepeatMode = (mode) async {
      _loopMode = switch (mode) {
        AudioServiceRepeatMode.one => LoopSetting.one,
        AudioServiceRepeatMode.all => LoopSetting.all,
        _ => LoopSetting.off,
      };
      _publishNotificationState();
      notifyListeners();
    };
    JustAudioBackground.onSetShuffleMode = (mode) async {
      _shuffle = mode == AudioServiceShuffleMode.all;
      _publishNotificationState();
      notifyListeners();
    };
    // Notification repeat/shuffle buttons are custom actions (audio_service
    // gives keycode-less actions a null PendingIntent, so taps did nothing).
    JustAudioBackground.onCustomAction = (name) async {
      if (name == 'peerm_repeat') {
        toggleLoop();
      } else if (name == 'peerm_shuffle') {
        toggleShuffle();
      }
    };
  }

  /// Live playback position, throttled to ~250 ms so the seek bar updates
  /// smoothly without rebuilding the whole player screen. Consume with a
  /// `StreamBuilder`, never with `notifyListeners()`.
  Stream<Duration> get positionStream => _player.createPositionStream(
        minPeriod: const Duration(milliseconds: 250),
        maxPeriod: const Duration(milliseconds: 250),
      );

  /// Starts an infinite radio mix based on [seedSong].
  Future<void> startRadio(Song seedSong) async {
    _lastInteraction = DateTime.now();
    _continuationToken = null;
    queueSourceId = 'radio';
    queueTitle = 'Radio (${seedSong.title})';
    _queue = [seedSong];
    _queueIndex = 0;
    currentSong = seedSong;
    notifyListeners();

    // Trigger initial background fetch of recommended tracks
    unawaited(fetchAndAppendRecommendations());

    await playSong(seedSong, queue: _queue, sourceId: 'radio', sourceTitle: queueTitle);
  }

  /// Fetches the next batch of recommendations and appends them to [_queue].
  Future<bool> fetchAndAppendRecommendations() async {
    if (_isLoadingRecommendations || _queue.isEmpty) return false;
    _isLoadingRecommendations = true;
    notifyListeners();

    try {
      final excludeIds = _queue.map((s) => s.id).toSet();
      final seed = currentSong ?? _queue.last;

      RecommendationBatch batch;
      if (_continuationToken != null) {
        batch = await RecommendationService.fetchContinuation(
          _continuationToken!,
          excludeVideoIds: excludeIds,
        );
      } else {
        batch = await RecommendationService.fetchRadio(
          seed,
          excludeVideoIds: excludeIds,
        );
      }

      if (batch.items.isNotEmpty) {
        _continuationToken = batch.continuationToken;
        final newSongs = batch.items.map((item) => item.toSong()).toList();
        _queue = [..._queue, ...newSongs];
        notifyListeners();
        return true;
      }

      // Offline / Empty fallback: pull from local library
      final offlineSongs = RecommendationService.getOfflineRecommendations(
        seed,
        library.songs,
        excludeSongIds: excludeIds,
      );
      if (offlineSongs.isNotEmpty) {
        _queue = [..._queue, ...offlineSongs];
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[PlayerService] fetchAndAppendRecommendations error: $e');
      return false;
    } finally {
      _isLoadingRecommendations = false;
      notifyListeners();
    }
  }

  int _playRequestToken = 0;

  /// Play [song], optionally in the context of [queue] (e.g. a playlist).
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    String? sourceId,
    String? sourceTitle,
  }) async {
    _lastInteraction = DateTime.now();
    RecommendationService.markPlayed(song.id);
    final token = ++_playRequestToken;

    // Android 13+ blocks the media notification unless the app holds the
    // notification permission. Ask for it (fire-and-forget) so the first
    // play shows the notification; the prompt does not delay playback.
    _requestNotificationPermissionIfNeeded();

    _queue = queue ?? library.songs;
    if (sourceId != null) {
      queueSourceId = sourceId;
      queueTitle = sourceTitle;
    } else if (queue == null) {
      queueSourceId = 'library';
      queueTitle = 'Library';
    }
    if (_queue.isEmpty) _queue = [song];
    _queueIndex = _queue.indexWhere((s) => s.id == song.id);
    if (_queueIndex < 0) {
      _queue = [song, ..._queue];
      _queueIndex = 0;
    }
    currentSong = song;
    notifyListeners();

    // Trigger pre-fetch if we are within 3 songs of the queue end and autoplay is on
    if (_autoplay && _queueIndex >= _queue.length - 3 && !_isLoadingRecommendations) {
      unawaited(fetchAndAppendRecommendations());
    }

    // The library's files have no embedded cover art, so use the generated
    // default artwork. Without artUri the media notification renders the app
    // launcher icon as a big placeholder instead of a proper album thumbnail.
    final artUri = await ArtworkService.defaultArtworkUri();
    if (token != _playRequestToken) return;

    try {
      // Load a SINGLE source (not the whole playlist) so advancing works on
      // every backend; our Dart queue drives next/previous/loop/shuffle.
      await _player.setLoopMode(LoopMode.off);
      if (token != _playRequestToken) return;

      final effectiveArtUri = (song.artwork != null && song.artwork!.startsWith('http'))
          ? Uri.tryParse(song.artwork!) ?? artUri
          : artUri;

      if (song.sourceDeviceId == 'stream') {
        final videoId = song.id.replaceFirst('stream_', '');
        final streamUri = await StreamCacheManager.resolveStreamUri(videoId);
        if (token != _playRequestToken) return;

        if (streamUri != null) {
          await _player.setAudioSource(
            AudioSource.uri(
              streamUri,
              headers: const {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                'Referer': 'https://www.youtube.com/',
              },
              tag: MediaItem(
                id: song.id,
                title: song.title,
                album: 'Pear Radio',
                artUri: effectiveArtUri,
              ),
            ),
          );
        } else {
          // If streaming failed, advance to next track
          debugPrint('[PlayerService] Stream resolution failed for ${song.title}');
          unawaited(next());
          return;
        }
      } else {
        await _player.setAudioSource(
          AudioSource.uri(
            Uri.file(library.songFile(song).path),
            tag: MediaItem(
              id: song.id,
              title: song.title,
              album: 'Pear Music',
              artUri: effectiveArtUri,
            ),
          ),
        );
      }
      if (token != _playRequestToken) return;

      await _player.play();
    } catch (e) {
      if (token == _playRequestToken) {
        debugPrint('[player] failed to play ${song.title}: $e');
      }
    }
    if (token == _playRequestToken) {
      _publishNotificationState();
      notifyListeners();
    }
  }

  /// Updates the current queue without restarting playback. Adjusts the active
  /// index to keep tracking [currentSong] in the updated list.
  void updateQueue(
    List<Song> newQueue, {
    String? sourceId,
    String? sourceTitle,
  }) {
    if (newQueue.isEmpty) return;
    _queue = List.from(newQueue);
    if (sourceId != null) {
      queueSourceId = sourceId;
      queueTitle = sourceTitle;
    }
    if (currentSong != null) {
      final idx = _queue.indexWhere((s) => s.id == currentSong!.id);
      if (idx >= 0) {
        _queueIndex = idx;
      } else {
        // Retain the current song at the beginning if not in the new filter.
        _queue = [currentSong!, ..._queue];
        _queueIndex = 0;
      }
    } else {
      _queueIndex = -1;
    }
    notifyListeners();
  }

  Future<void> pause({bool smooth = true}) async {
    _lastInteraction = DateTime.now();
    if (!_player.playing) return;
    final originalVol = _player.volume;
    if (smooth && originalVol > 0.05) {
      await _fadeVolume(0.0, duration: const Duration(milliseconds: 90));
      await _player.pause();
      await _player.setVolume(originalVol);
    } else {
      await _player.pause();
    }
    notifyListeners();
  }

  Future<void> toggle() async {
    _lastInteraction = DateTime.now();
    if (currentSong == null) {
      if (library.songs.isNotEmpty) {
        await playSong(library.songs.first);
      }
      return;
    }
    if (_player.playing) {
      await pause(smooth: true);
    } else {
      await _player.play();
      notifyListeners();
    }
  }

  Future<void> next() async {
    _lastInteraction = DateTime.now();
    if (_queue.isEmpty) return;
    if (_loopMode == LoopSetting.one) {
      await _replayCurrent();
      return;
    }
    final nextIndex = _pickNextIndex();
    if (nextIndex == null) {
      // Check 2-hour inactivity guard
      if (DateTime.now().difference(_lastInteraction) > const Duration(hours: 2)) {
        debugPrint('[PlayerService] Autoplay paused due to 2-hour inactivity guard.');
        await _player.pause();
        await _player.seek(Duration.zero);
        notifyListeners();
        return;
      }

      // Autoplay: fetch next batch and continue
      if (_autoplay && currentSong != null) {
        final appended = await fetchAndAppendRecommendations();
        if (appended && _queueIndex + 1 < _queue.length) {
          await playSong(_queue[_queueIndex + 1], queue: _queue);
          return;
        }
      }

      // Loop off + end of queue: stop at the end.
      await _player.pause();
      await _player.seek(Duration.zero);
      notifyListeners();
      return;
    }
    await playSong(_queue[nextIndex], queue: _queue);
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    if (_loopMode == LoopSetting.one) {
      await _replayCurrent();
      return;
    }
    // Restart the current track if we're more than 3s in.
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      notifyListeners();
      return;
    }
    final prev = _pickPreviousIndex();
    if (prev == null) {
      await _player.seek(Duration.zero);
      notifyListeners();
      return;
    }
    await playSong(_queue[prev], queue: _queue);
  }

  Future<void> toggleLoop() {
    _loopMode = switch (_loopMode) {
      LoopSetting.off => LoopSetting.all,
      LoopSetting.all => LoopSetting.one,
      LoopSetting.one => LoopSetting.off,
    };
    _publishNotificationState();
    notifyListeners();
    return Future.value();
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    _publishNotificationState();
    notifyListeners();
  }

  /// Index of the next track, honouring shuffle + loop modes. Null means
  /// "stop" (loop off and at the end of the queue).
  int? _pickNextIndex() {
    if (_queue.isEmpty) return null;
    if (_shuffle) {
      if (_queue.length == 1) return 0;
      var r = _queueIndex;
      while (r == _queueIndex) {
        r = _random.nextInt(_queue.length);
      }
      return r;
    }
    final n = _queueIndex + 1;
    if (n < _queue.length) return n;
    return _loopMode == LoopSetting.all ? 0 : null;
  }

  int? _pickPreviousIndex() {
    if (_queue.isEmpty) return null;
    if (_shuffle) {
      if (_queue.length == 1) return 0;
      var r = _queueIndex;
      while (r == _queueIndex) {
        r = _random.nextInt(_queue.length);
      }
      return r;
    }
    final p = _queueIndex - 1;
    if (p >= 0) return p;
    return _loopMode == LoopSetting.all ? _queue.length - 1 : null;
  }

  Future<void> _replayCurrent() async {
    await _player.seek(Duration.zero);
    await _player.play();
    notifyListeners();
  }

  /// Keep the notification's repeat / shuffle icons in sync with our state.
  void _publishNotificationState() {
    final repeat = switch (_loopMode) {
      LoopSetting.off => AudioServiceRepeatMode.none,
      LoopSetting.all => AudioServiceRepeatMode.all,
      LoopSetting.one => AudioServiceRepeatMode.one,
    };
    final shuffle =
        _shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none;
    JustAudioBackground.publishRepeatMode(repeat);
    JustAudioBackground.publishShuffleMode(shuffle);
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> setVolume(double value) async {
    await _player.setVolume(value.clamp(0.0, 1.0));
  }

  /// Android 13+ (API 33+) requires the POST_NOTIFICATIONS runtime permission
  /// for app notifications to show. The media notification from
  /// just_audio_background is affected on many devices (vivo/Oppo/Xiaomi are
  /// strict). Request it once on the first play. No-op on other platforms.
  Future<void> _requestNotificationPermissionIfNeeded() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.notification.status;
      if (!status.isGranted) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint('[player] notification permission request failed: $e');
    }
  }

  Future<void> stop() async {
    await _player.stop();
    currentSong = null;
    _queue = [];
    _queueIndex = -1;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}

