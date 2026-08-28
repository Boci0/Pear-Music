import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/song.dart';
import 'artwork_service.dart';
import 'debug_log.dart';
import 'identity_service.dart';
import 'library_service.dart';
import 'recommendation_service.dart';
import 'stream_cache_manager.dart';

/// How the queue advances when a track ends or the user skips.
enum LoopSetting { off, all, one }

/// Route through which the active song is being served.
enum StreamRouteType {
  cached, // Local disk cache (0ms instant)
  direct, // Primary Innertube direct stream
  fallback, // Secondary Piped / yt-dlp fallback
  local, // Local file
}

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
  bool _isAdvancing = false;
  bool _isLoadingTrack = false;
  int _consecutiveStreamFailures = 0;
  bool _isPreloadingUpcoming = false;

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

  StreamRouteType _currentRouteType = StreamRouteType.local;
  StreamRouteType get currentRouteType => _currentRouteType;
  int _lastTrackLoadMs = 0;
  int get lastTrackLoadMs => _lastTrackLoadMs;

  Song? get song => currentSong;
  Duration? get position => _player.position;
  Duration? get duration => _player.duration;
  bool get playing => _player.playing;
  double get volume => _player.volume;
  bool get hasLoaded => currentSong != null;
  bool get loudnessNormalization => _loudnessNormalization;
  bool get isLoadingTrack => _isLoadingTrack;

  bool get isPreloadingUpcoming => _isPreloadingUpcoming || _isLoadingRecommendations;

  bool get hasNextTrack => _queueIndex >= 0 && _queueIndex + 1 < _queue.length;

  bool get isNextTrackReady {
    if (!hasNextTrack) return true;
    final nextSong = _queue[_queueIndex + 1];
    if (nextSong.sourceDeviceId != 'stream') return true;
    final videoId = nextSong.id.replaceFirst('stream_', '');
    return StreamCacheManager.isStreamCachedSync(videoId);
  }

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
    unawaited(StreamCacheManager.warmUp());

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
        DebugLog.write('[player] Track completed naturally; advancing next');
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
    unawaited(() async {
      final firstOk = await fetchAndAppendRecommendations();
      if (firstOk && _queue.length < 25) {
        await fetchAndAppendRecommendations();
      }
    }());

    await playSong(seedSong, sourceId: 'radio', sourceTitle: queueTitle);
  }

  /// Fetches the next batch of recommendations and appends them to [_queue].
  Future<bool> fetchAndAppendRecommendations() async {
    if (_isLoadingRecommendations || _queue.isEmpty) return false;
    _isLoadingRecommendations = true;
    notifyListeners();

    try {
      final excludeIds = RecommendationService.normalizeVideoIds(_queue.map((s) => s.id));
      final seed = currentSong ?? _queue.last;
      DebugLog.write('[radio] Fetching recommendations for seed "${seed.title}" (${excludeIds.length} excluded)');

      RecommendationBatch batch;
      if (_continuationToken != null) {
        batch = await RecommendationService.fetchContinuation(
          _continuationToken!,
          excludeVideoIds: excludeIds,
        );
        if (batch.items.isEmpty) {
          _continuationToken = null;
          batch = await RecommendationService.fetchRadio(
            seed,
            excludeVideoIds: excludeIds,
          );
        }
      } else {
        batch = await RecommendationService.fetchRadio(
          seed,
          excludeVideoIds: excludeIds,
        );
      }

      if (batch.items.isNotEmpty) {
        _continuationToken = batch.continuationToken;
        final existingVideoIds = RecommendationService.normalizeVideoIds(_queue.map((s) => s.id));
        final existingTitles = _queue.map((s) => s.title.toLowerCase().trim()).toSet();

        final newSongs = <Song>[];
        for (final item in batch.items) {
          if (existingVideoIds.contains(item.videoId)) continue;
          final cleanSong = item.toSong();
          final cleanTitle = cleanSong.title.toLowerCase().trim();
          if (existingTitles.contains(cleanTitle)) continue;

          existingVideoIds.add(item.videoId);
          existingTitles.add(cleanTitle);
          newSongs.add(cleanSong);
        }

        if (newSongs.isNotEmpty) {
          _queue = [..._queue, ...newSongs];
          _preloadUpcomingStreams();
          DebugLog.write('[radio] Appended ${newSongs.length} unique tracks (queue size: ${_queue.length})');
          notifyListeners();
          return true;
        }
      }

      // Offline / Empty fallback: pull from local library
      final offlineSongs = RecommendationService.getOfflineRecommendations(
        seed,
        library.songs,
        excludeSongIds: excludeIds,
      );
      if (offlineSongs.isNotEmpty) {
        _queue = [..._queue, ...offlineSongs];
        DebugLog.write('[radio] Appended ${offlineSongs.length} offline library recommendations');
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      DebugLog.write('[radio] fetchAndAppendRecommendations error: $e');
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
    _isAdvancing = true;
    _isLoadingTrack = true;

    // Android 13+ blocks the media notification unless the app holds the
    // notification permission. Ask for it (fire-and-forget) so the first
    // play shows the notification; the prompt does not delay playback.
    _requestNotificationPermissionIfNeeded();

    if (queue != null) {
      _queue = List<Song>.from(queue);
    } else if (_queue.isEmpty) {
      _queue = library.songs.isNotEmpty ? List<Song>.from(library.songs) : [song];
    }
    if (sourceId != null) {
      queueSourceId = sourceId;
      queueTitle = sourceTitle;
    } else if (queue == null && queueSourceId == null) {
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

    // STOP previous audio immediately so there is zero bleed
    try {
      if (_player.playing) {
        await _player.stop();
      }
    } catch (_) {}
    if (token != _playRequestToken) return;

    // Speculatively pre-resolve and cache upcoming queue streams
    _preloadUpcomingStreams();

    // Trigger proactive background pre-fetch when within 10 songs of the queue end
    if (_autoplay && _queueIndex >= _queue.length - 10 && !_isLoadingRecommendations) {
      unawaited(fetchAndAppendRecommendations());
    }

    final effectiveArtUri = await ArtworkService.songArtworkUri(song);
    if (token != _playRequestToken) return;

    final stopwatch = Stopwatch()..start();
    try {
      await _player.setLoopMode(LoopMode.off);
      if (token != _playRequestToken) return;

      if (song.sourceDeviceId == 'stream') {
        final videoId = RecommendationService.extractVideoId(song.id) ?? song.id.replaceFirst('stream_', '');
        final mediaTag = MediaItem(
          id: song.id,
          title: song.title,
          album: 'Pear Radio',
          artUri: effectiveArtUri,
        );

        final cachedFile = await StreamCacheManager.getCachedFile(videoId);
        if (token != _playRequestToken) return;

        if (cachedFile != null && await cachedFile.exists()) {
          _currentRouteType = StreamRouteType.cached;
          _lastTrackLoadMs = stopwatch.elapsedMilliseconds;
          DebugLog.write('[player] Playing from DISK CACHE (${_lastTrackLoadMs}ms): ${song.title} [$videoId]');
          await _player.setAudioSource(
            AudioSource.file(cachedFile.path, tag: mediaTag),
          );
        } else {
          final streamUrl = await StreamCacheManager.extractDirectStreamUrl(videoId);
          if (token != _playRequestToken) return;

          if (streamUrl != null && streamUrl.startsWith('http')) {
            _currentRouteType = StreamRouteType.direct;
            _lastTrackLoadMs = stopwatch.elapsedMilliseconds;
            DebugLog.write('[player] Playing DIRECT STREAM (${_lastTrackLoadMs}ms): ${song.title} [$videoId]');
            await _player.setAudioSource(
              AudioSource.uri(
                Uri.parse(streamUrl),
                headers: const {
                  'User-Agent':
                      'com.google.android.apps.youtube.music/6.42.52 (Linux; U; Android 14)',
                  'Referer': 'https://music.youtube.com/',
                },
                tag: mediaTag,
              ),
            );
            // Asynchronously cache in background once playback has started
            unawaited(StreamCacheManager.ensureStreamCached(videoId));
          } else {
            // Fallback: wait for cached file
            final downloadedFile = await StreamCacheManager.ensureStreamCached(videoId);
            if (token != _playRequestToken) return;

            if (downloadedFile != null && await downloadedFile.exists()) {
              _currentRouteType = StreamRouteType.cached;
              _lastTrackLoadMs = stopwatch.elapsedMilliseconds;
              DebugLog.write('[player] Playing from DOWNLOADED CACHE (${_lastTrackLoadMs}ms): ${song.title} [$videoId]');
              await _player.setAudioSource(
                AudioSource.file(downloadedFile.path, tag: mediaTag),
              );
            } else {
              _consecutiveStreamFailures++;
              DebugLog.write(
                '[player] Stream failed for ${song.title} '
                '(failure $_consecutiveStreamFailures/3)',
              );
              if (_consecutiveStreamFailures >= 3) {
                DebugLog.write('[player] Circuit breaker tripped, halting playback');
                _isAdvancing = false;
                _isLoadingTrack = false;
                await _player.pause();
                notifyListeners();
                return;
              }
              unawaited(next());
              return;
            }
          }
        }
      } else {
        // Local song: play directly from local file
        _currentRouteType = StreamRouteType.local;
        _lastTrackLoadMs = stopwatch.elapsedMilliseconds;
        DebugLog.write('[player] Playing LOCAL file (${_lastTrackLoadMs}ms): ${song.title}');
        final file = library.songFile(song);
        await _player.setAudioSource(
          AudioSource.file(
            file.path,
            tag: MediaItem(
              id: song.id,
              title: song.title,
              album: 'Local Music',
              artUri: effectiveArtUri,
            ),
          ),
        );
      }

      if (token != _playRequestToken) return;
      _isLoadingTrack = false;
      await _player.play();
      _consecutiveStreamFailures = 0;
      _preloadUpcomingStreams();
    } catch (e) {
      DebugLog.write('[player] playSong error: $e');
      if (token != _playRequestToken) return;
      _consecutiveStreamFailures++;
      if (_consecutiveStreamFailures >= 3) {
        _isAdvancing = false;
        _isLoadingTrack = false;
        await _player.pause();
        notifyListeners();
        return;
      }
      unawaited(next());
    } finally {
      _isAdvancing = false;
      _isLoadingTrack = false;
      notifyListeners();
    }
  }

  /// Speculatively pre-caches upcoming radio tracks along the current queue.
  void _preloadUpcomingStreams() {
    if (_queueIndex < 0 || _queue.isEmpty) return;
    final upcomingVideoIds = <String>[];
    for (int idx = _queueIndex + 1; idx < _queue.length; idx++) {
      final s = _queue[idx];
      if (s.sourceDeviceId == 'stream') {
        final vId = RecommendationService.extractVideoId(s.id) ?? s.id.replaceFirst('stream_', '');
        if (vId.isNotEmpty) {
          upcomingVideoIds.add(vId);
        }
      }
    }
    if (upcomingVideoIds.isNotEmpty) {
      final nextTrackId = upcomingVideoIds.first;
      final isNextAlreadyCached = StreamCacheManager.isStreamCachedSync(nextTrackId);
      if (!isNextAlreadyCached) {
        _isPreloadingUpcoming = true;
        notifyListeners();
      }
      StreamCacheManager.preloadSlidingWindow(
        upcomingVideoIds,
        onTrackCached: (vId) {
          if (vId == nextTrackId) {
            _isPreloadingUpcoming = false;
            notifyListeners();
          }
        },
      );
    } else {
      _isPreloadingUpcoming = false;
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
    _preloadUpcomingStreams();
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
          final target = _queue[_queueIndex + 1];
          _queueIndex = _queueIndex + 1;
          currentSong = target;
          notifyListeners();
          await playSong(target, queue: _queue);
          return;
        }
      }

      // Loop off + end of queue: stop at the end.
      await _player.pause();
      await _player.seek(Duration.zero);
      notifyListeners();
      return;
    }
    // Optimistically update UI immediately to eliminate skip perceived delay
    final nextTrack = _queue[nextIndex];
    _queueIndex = nextIndex;
    currentSong = nextTrack;
    DebugLog.write('[player] Advancing to track ${_queueIndex + 1}/${_queue.length}: ${nextTrack.title}');
    notifyListeners();

    await playSong(nextTrack, queue: _queue);
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
    // Optimistically update UI immediately
    final prevTrack = _queue[prev];
    _queueIndex = prev;
    currentSong = prevTrack;
    notifyListeners();

    await playSong(prevTrack, queue: _queue);
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

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _queue.length ||
        newIndex < 0 ||
        newIndex > _queue.length) {
      return;
    }
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final mutableQueue = List<Song>.from(_queue);
    final item = mutableQueue.removeAt(oldIndex);
    mutableQueue.insert(newIndex, item);
    _queue = mutableQueue;
    if (currentSong != null) {
      _queueIndex = _queue.indexWhere((s) => s.id == currentSong!.id);
    }
    _preloadUpcomingStreams();
    notifyListeners();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) {
      return;
    }
    if (index == _queueIndex) {
      unawaited(next());
    }
    final mutableQueue = List<Song>.from(_queue);
    mutableQueue.removeAt(index);
    _queue = mutableQueue;
    if (currentSong != null) {
      _queueIndex = _queue.indexWhere((s) => s.id == currentSong!.id);
    }
    _preloadUpcomingStreams();
    notifyListeners();
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

