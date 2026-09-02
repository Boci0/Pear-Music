import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/song.dart';
import 'artwork_service.dart';
import 'debug_log.dart';
import 'identity_service.dart';
import 'library_service.dart';
import 'pear_audio_handler.dart';
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
  final Set<String> _lockedSongIds = {};

  String? _continuationToken;
  bool _isLoadingRecommendations = false;
  DateTime _lastInteraction = DateTime.now();
  bool _isAdvancing = false;
  bool _isLoadingTrack = false;
  bool _isBufferingNext = false; // true while resolving next track's URL
  String? _bufferingVideoId;    // which track is being resolved
  int _consecutiveStreamFailures = 0;
  bool _isPreloadingUpcoming = false;
  bool _pendingNaturalAdvance = false;

  Timer? _sleepTimer;
  DateTime? _sleepTimerEndTime;
  bool _sleepTimerEndOfSong = false;

  final List<StreamSubscription> _subs = [];
  final PearAudioHandler? audioHandler;

  PlayerService(this.library, {this.identity, this.audioHandler, AudioPlayer? player}) {
    _player = player ?? AudioPlayer();
    _initAudioHandler();
  }

  StreamRouteType _currentRouteType = StreamRouteType.local;
  StreamRouteType get currentRouteType => _currentRouteType;
  int _lastTrackLoadMs = 0;
  int get lastTrackLoadMs => _lastTrackLoadMs;

  Song? get song => currentSong;
  Duration? get position => _player.position;
  Duration? get duration => _player.duration;
  bool get playing => _player.playing;
  double _userVolume = 1.0;
  double get volume => _userVolume;
  bool get hasLoaded => currentSong != null;
  bool get loudnessNormalization => _loudnessNormalization;
  bool get isLoadingTrack => _isLoadingTrack;
  bool get isBufferingNext => _isBufferingNext;
  String? get bufferingVideoId => _bufferingVideoId;

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
    final originalVol = _userVolume;
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
    unawaited(_requestNotificationPermissionIfNeeded());

    // Never let the underlying player loop by itself: loop modes are
    // implemented in Dart (single-source loads). This is also what fixes the
    // "loops on 1 song" issue on backends that don't advance playlists.
    _userVolume = _player.volume;
    unawaited(_player.setLoopMode(LoopMode.off));

    // NOTE: `positionStream` is deliberately NOT forwarded through
    // notifyListeners(). It fires many times per second while playing and
    // would rebuild every widget watching AppController (HomeShell keeps all
    // three tabs alive via IndexedStack) on every tick: the single biggest
    // cause of UI jank. Widgets that need live position subscribe to
    // [positionStream] directly with a StreamBuilder instead (see PlayerScreen
    // seek bar). We still notify on everything that changes rarely: duration,
    // play/pause state and processing state.
    _subs.add(_player.durationStream.listen((_) {
      _publishNotificationState();
      notifyListeners();
    }));
    _subs.add(_player.playerStateStream.listen((state) {
      if (state.playing && _isLoadingTrack) {
        _isLoadingTrack = false;
      }
      _publishNotificationState();
      notifyListeners();
    }));
    _subs.add(_player.playbackEventStream.listen((_) {
      _publishNotificationState();
    }));
    // Auto-advance (loop / shuffle aware) when a track finishes.
    _subs.add(_player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && _queue.isNotEmpty) {
        if (_isLoadingTrack || _isAdvancing) {
          _pendingNaturalAdvance = true;
          DebugLog.write('[player] Completed event arrived while loading/advancing; queued pending advance');
          return;
        }
        DebugLog.write('[player] Track completed naturally; advancing next');
        if (_sleepTimerEndOfSong) {
          _sleepTimerEndOfSong = false;
          unawaited(pause(smooth: true));
        } else {
          unawaited(next());
        }
      }
    }));
    _publishNotificationState();
  }

  void _initAudioHandler() {
    final h = audioHandler;
    if (h == null) return;

    h.onPlay = () => resume();
    h.onPause = () => pause(smooth: false);
    h.onSkipToNext = () => next();
    h.onSkipToPrevious = () => previous();
    h.onSeek = (pos) => seek(pos);
    h.onSetRepeatMode = (mode) async {
      _loopMode = switch (mode) {
        AudioServiceRepeatMode.one => LoopSetting.one,
        AudioServiceRepeatMode.all => LoopSetting.all,
        _ => LoopSetting.off,
      };
      _publishNotificationState();
      notifyListeners();
    };
    h.onSetShuffleMode = (mode) async {
      _shuffle = mode == AudioServiceShuffleMode.all;
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
          await next();
          break;
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

  /// Rerolls upcoming recommendations in the queue (songs after current song).
  /// Preserves any tracks explicitly marked as locked in the upcoming queue.
  Future<bool> rerollUpcomingQueue() async {
    if (currentSong == null || _queue.isEmpty) return false;
    if (_isLoadingRecommendations) return false;
    _isLoadingRecommendations = true;
    notifyListeners();

    try {
      final activeIndex = _queueIndex >= 0 ? _queueIndex : 0;
      final head = _queue.sublist(0, activeIndex + 1);
      final upcoming = _queue.length > activeIndex + 1 ? _queue.sublist(activeIndex + 1) : <Song>[];
      final lockedUpcoming = upcoming.where((s) => _lockedSongIds.contains(s.id)).toList();

      // Reset continuation token so we query fresh recommendations
      _continuationToken = null;

      final excludeIds = RecommendationService.normalizeVideoIds([
        ...head.map((s) => s.id),
        ...lockedUpcoming.map((s) => s.id),
      ]);

      final seed = currentSong ?? head.last;
      DebugLog.write('[radio] Rerolling seed for "${seed.title}" (preserving ${lockedUpcoming.length} locked tracks)');

      RecommendationBatch batch;
      try {
        batch = await RecommendationService.fetchRadio(
          seed,
          excludeVideoIds: excludeIds,
        );
      } catch (e) {
        DebugLog.write('[radio] Online reroll error ($e), falling back to offline library');
        batch = const RecommendationBatch(items: []);
      }

      final freshSongs = <Song>[];
      if (batch.items.isNotEmpty) {
        _continuationToken = batch.continuationToken;
        final existingVideoIds = Set<String>.from(excludeIds);
        final existingTitles = [
          ...head.map((s) => s.title.toLowerCase().trim()),
          ...lockedUpcoming.map((s) => s.title.toLowerCase().trim()),
        ].toSet();

        for (final item in batch.items) {
          if (existingVideoIds.contains(item.videoId)) continue;
          final cleanSong = item.toSong();
          final cleanTitle = cleanSong.title.toLowerCase().trim();
          if (existingTitles.contains(cleanTitle)) continue;

          existingVideoIds.add(item.videoId);
          existingTitles.add(cleanTitle);
          freshSongs.add(cleanSong);
        }
      }

      if (freshSongs.isEmpty) {
        final offlineExcludeIds = {
          ...head.map((s) => s.id),
          ...upcoming.map((s) => s.id),
        };
        final offline = RecommendationService.getOfflineRecommendations(
          seed,
          library.songs,
          excludeSongIds: offlineExcludeIds,
        );
        freshSongs.addAll(offline);
      }

      _queue = [...head, ...lockedUpcoming, ...freshSongs];
      _preloadUpcomingStreams();
      DebugLog.write('[radio] Reroll complete: queue now has ${_queue.length} tracks (${lockedUpcoming.length} locked, ${freshSongs.length} new)');
      notifyListeners();
      return true;
    } catch (e) {
      DebugLog.write('[radio] Reroll failed: $e');
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
    _pendingNaturalAdvance = false;
    _preloadDebounceTimer?.cancel();
    _isAdvancing = true;
    _isLoadingTrack = true;

    // Immediately pause existing playback so the previous track does not
    // continue playing while the new track is resolving, downloading, or buffering.
    if (_player.playing) {
      unawaited(_player.pause());
    }

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
    _lastTrackLoadMs = -1;
    _updateActiveQueueCacheProtection();
    DebugLog.write(
      '[player] === playSong START === token=$token '
      'song="${song.title}" id=${song.id} source=${song.sourceDeviceId} '
      'queueIdx=$_queueIndex queueLen=${_queue.length} '
      'queueSource=$queueSourceId',
    );
    notifyListeners();

    // Synchronously parse network artwork for streams or resolve local artwork with fast timeout
    final Uri effectiveArtUri;
    if (song.artwork != null && song.artwork!.startsWith('http')) {
      effectiveArtUri = Uri.tryParse(song.artwork!) ?? await ArtworkService.defaultArtworkUri();
    } else {
      effectiveArtUri = await ArtworkService.songArtworkUri(song).timeout(
        const Duration(milliseconds: 150),
        onTimeout: () => ArtworkService.defaultArtworkUri(),
      );
    }
    if (token != _playRequestToken) return;
    audioHandler?.updateSongMediaItem(
      song,
      duration: _player.duration,
      artUri: effectiveArtUri,
    );

    final stopwatch = Stopwatch()..start();
    try {
      await _player.setLoopMode(LoopMode.off);
      if (token != _playRequestToken) return;

      if (song.sourceDeviceId == 'stream') {
        final videoId = RecommendationService.extractVideoId(song.id) ?? song.id.replaceFirst('stream_', '');
        DebugLog.write('[player] Stream path: checking active preload for $videoId');
        StreamCacheManager.cancelPreload(exceptVideoId: videoId);
        DebugLog.write('[player] Resolved videoId=$videoId, checking disk cache...');

        final cachedFile = await StreamCacheManager.getCachedFile(videoId);
        if (token != _playRequestToken) return;

        if (cachedFile != null && await cachedFile.exists()) {
          _currentRouteType = StreamRouteType.cached;
          _lastTrackLoadMs = stopwatch.elapsedMilliseconds;
          _isBufferingNext = false;
          _bufferingVideoId = null;
          notifyListeners();
          DebugLog.write('[player] DISK CACHE HIT (${_lastTrackLoadMs}ms): "${song.title}" [$videoId] file=${cachedFile.path}');
          await _player.setAudioSource(
            AudioSource.file(cachedFile.path),
          );
          _resetStreamFailureCounters();
        } else {
          // Signal buffering state so the UI shows "Connecting to Pear Radio..."
          _isBufferingNext = true;
          _bufferingVideoId = videoId;
          notifyListeners();

          DebugLog.write('[player] DISK CACHE MISS for $videoId, downloading via ensureStreamCached...');
          File? downloadedFile = await StreamCacheManager.ensureStreamCached(videoId);

          // Retry once after short delay if initial resolution returned null
          if (downloadedFile == null && token == _playRequestToken) {
            DebugLog.write('[player] Initial stream fetch for $videoId returned null, retrying once...');
            await Future.delayed(const Duration(milliseconds: 500));
            if (token != _playRequestToken) return;
            downloadedFile = await StreamCacheManager.ensureStreamCached(videoId);
          }

          _isBufferingNext = false;
          _bufferingVideoId = null;
          if (token != _playRequestToken) {
            DebugLog.write('[player] Token stale after download ($token != $_playRequestToken), aborting');
            return;
          }

          if (downloadedFile != null && await downloadedFile.exists()) {
            _currentRouteType = StreamRouteType.direct;
            _lastTrackLoadMs = stopwatch.elapsedMilliseconds;
            notifyListeners();
            DebugLog.write('[player] DOWNLOADED OK (${_lastTrackLoadMs}ms): "${song.title}" [$videoId] file=${downloadedFile.path} size=${await downloadedFile.length()} bytes');
            await _player.setAudioSource(
              AudioSource.file(downloadedFile.path),
            );
            _resetStreamFailureCounters();
          } else {
            _consecutiveStreamFailures++;
            final fastFail = StreamCacheManager.isFastFailMode;
            DebugLog.write(
              '[player] Stream failed for ${song.title} '
              '(failure $_consecutiveStreamFailures/3, fastFail=$fastFail)',
            );
            _isAdvancing = false;
            _isLoadingTrack = false;
            notifyListeners();

            // Persistently keep the queue alive by auto-advancing to the next song instead of stopping
            if (_consecutiveStreamFailures < 3 && _queue.length > 1) {
              DebugLog.write('[player] Auto-advancing past failed stream "${song.title}" to next track');
              unawaited(next());
              return;
            }

            await _player.pause();
            notifyListeners();
            return;
          }
        }
      } else {
        // Local song: play directly from local file
        _currentRouteType = StreamRouteType.local;
        _lastTrackLoadMs = stopwatch.elapsedMilliseconds;
        _isBufferingNext = false;
        _bufferingVideoId = null;
        notifyListeners();
        DebugLog.write('[player] Playing LOCAL file (${_lastTrackLoadMs}ms): ${song.title}');
        final file = library.songFile(song);
        if (!await file.exists()) {
          DebugLog.write('[player] File missing on disk for ${song.title} (${file.path})');
          _isLoadingTrack = false;
          _isAdvancing = false;
          notifyListeners();
          return;
        }
        await _player.setAudioSource(
          AudioSource.file(file.path),
        );
      }

      if (token != _playRequestToken) {
        DebugLog.write('[player] Token stale before play() ($token != $_playRequestToken), aborting');
        return;
      }
      DebugLog.write('[player] Calling _player.play() for "${song.title}"');
      await _player.play();
      _isLoadingTrack = false;
      _isAdvancing = false;
      _consecutiveStreamFailures = 0;
      _publishNotificationState();
      notifyListeners();
      DebugLog.write('[player] === playSong SUCCESS === "${song.title}" queueIdx=$_queueIndex, triggering preload');
      _preloadUpcomingStreams(delay: const Duration(milliseconds: 500));
      if (_pendingNaturalAdvance || _player.processingState == ProcessingState.completed) {
        _pendingNaturalAdvance = false;
        DebugLog.write('[player] Song reached completed state during/immediately after play setup; auto-advancing next');
        unawaited(next());
      }
    } catch (e) {
      DebugLog.write('[player] playSong ERROR: $e');
      if (token != _playRequestToken) return;
      _consecutiveStreamFailures++;
      _isAdvancing = false;
      _isLoadingTrack = false;
      await _player.pause();
      notifyListeners();
    } finally {
      if (token == _playRequestToken) {
        _isAdvancing = false;
        _isLoadingTrack = false;
        _isBufferingNext = false;
        _bufferingVideoId = null;
        notifyListeners();
      }
    }
  }

  /// Resets both the player's consecutive-failure counter and the stream
  /// cache's failure counter. Called after any successful playback to clear
  /// fast-fail mode once YouTube rate-limiting subsides.
  void _resetStreamFailureCounters() {
    if (_consecutiveStreamFailures > 0 || StreamCacheManager.isFastFailMode) {
      DebugLog.write('[player] Resetting stream failure counters (was $_consecutiveStreamFailures failures)');
    }
    _consecutiveStreamFailures = 0;
    StreamCacheManager.resetFailureCounter();
  }

  Timer? _preloadDebounceTimer;

  /// Kicks off a debounced 1-track lookahead preloader for the next stream
  /// track in the queue. Waits 2 seconds
  /// before initiating background download so rapid song skips consume 0 KB of data.
  void _preloadUpcomingStreams({Duration delay = const Duration(seconds: 2)}) {
    _preloadDebounceTimer?.cancel();
    if (_queueIndex < 0 || _queue.isEmpty) {
      DebugLog.write('[preload] Skipping preload: queueIdx=$_queueIndex queueLen=${_queue.length}');
      return;
    }
    final upcomingVideoIds = <String>[];
    if (_shuffle) {
      for (int i = 0; i < _queue.length; i++) {
        if (i == _queueIndex) continue;
        final s = _queue[i];
        if (s.sourceDeviceId == 'stream') {
          final vId = RecommendationService.extractVideoId(s.id) ?? s.id.replaceFirst('stream_', '');
          if (vId.isNotEmpty && !upcomingVideoIds.contains(vId)) upcomingVideoIds.add(vId);
        }
      }
    } else {
      for (int idx = _queueIndex + 1; idx < _queue.length; idx++) {
        final s = _queue[idx];
        if (s.sourceDeviceId == 'stream') {
          final vId = RecommendationService.extractVideoId(s.id) ?? s.id.replaceFirst('stream_', '');
          if (vId.isNotEmpty && !upcomingVideoIds.contains(vId)) upcomingVideoIds.add(vId);
        }
      }
      if (_loopMode == LoopSetting.all) {
        for (int idx = 0; idx <= _queueIndex; idx++) {
          final s = _queue[idx];
          if (s.sourceDeviceId == 'stream') {
            final vId = RecommendationService.extractVideoId(s.id) ?? s.id.replaceFirst('stream_', '');
            if (vId.isNotEmpty && !upcomingVideoIds.contains(vId)) upcomingVideoIds.add(vId);
          }
        }
      }
    }
    if (upcomingVideoIds.isEmpty) {
      if (_autoplay && currentSong != null && (queueSourceId == 'radio' || currentSong?.sourceDeviceId == 'stream') && !_isLoadingRecommendations) {
        DebugLog.write('[preload] Queue near end with autoplay ON, pre-fetching recommendations...');
        unawaited(fetchAndAppendRecommendations());
      }
      DebugLog.write('[preload] No upcoming stream tracks to preload');
      _isPreloadingUpcoming = false;
      notifyListeners();
      return;
    }
    final nextTrackId = upcomingVideoIds.first;
    final isNextCached = StreamCacheManager.isStreamCachedSync(nextTrackId);
    if (isNextCached) {
      DebugLog.write('[preload] Next track $nextTrackId already cached on disk');
      _isPreloadingUpcoming = false;
      notifyListeners();
      return;
    }

    final token = _playRequestToken;
    _preloadDebounceTimer = Timer(delay, () {
      if (token != _playRequestToken) return;
      if (!_player.playing && _queueIndex < 0) return;
      DebugLog.write(
        '[preload] Starting 1-track lookahead preloader: next=$nextTrackId',
      );
      _isPreloadingUpcoming = true;
      notifyListeners();

      // Strict 1-track lookahead window to prevent clogging internet bandwidth
      final nextTrackWindow = upcomingVideoIds.take(1).toList();
      StreamCacheManager.preloadSlidingWindow(nextTrackWindow, onTrackCached: (cachedId) {
        DebugLog.write('[preload] onTrackCached: $cachedId');
        if (cachedId == nextTrackId) {
          _isPreloadingUpcoming = false;
          notifyListeners();
        }
      });
    });
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
    _updateActiveQueueCacheProtection();
    _preloadUpcomingStreams();
    notifyListeners();
  }

  void _updateActiveQueueCacheProtection() {
    final vIds = <String>{};
    for (final song in _queue) {
      if (song.sourceDeviceId == 'stream') {
        final vId = RecommendationService.extractVideoId(song.id) ?? song.id.replaceFirst('stream_', '');
        if (vId.isNotEmpty) vIds.add(vId);
      }
    }
    StreamCacheManager.setActiveQueueVideoIds(vIds);
  }

  Future<void> pause({bool smooth = false}) async {
    _lastInteraction = DateTime.now();
    _preloadDebounceTimer?.cancel();
    StreamCacheManager.cancelPreload();
    if (!_player.playing) return;
    await _player.pause();
    await _player.setVolume(_userVolume > 0.05 ? _userVolume : 1.0);
    _publishNotificationState();
    notifyListeners();
  }

  Future<void> resume() async {
    _lastInteraction = DateTime.now();
    if (currentSong == null) {
      if (library.songs.isNotEmpty) {
        await playSong(library.songs.first);
      }
      return;
    }
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    await _player.setVolume(_userVolume);
    try {
      await _player.play();
    } catch (e) {
      DebugLog.write('[player] resume failed ($e), reloading track: ${currentSong?.title}');
      if (currentSong != null) {
        await playSong(currentSong!);
      }
    }
    _publishNotificationState();
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
    try {
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

        // Loop off + end of queue: stop cleanly at the end.
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
    } catch (e) {
      DebugLog.write('[player] next error: $e');
    }
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    try {
      if (_loopMode == LoopSetting.one) {
        await _replayCurrent();
        return;
      }
      final pos = _player.position;
      if (pos != null && pos > const Duration(seconds: 3)) {
        await seek(Duration.zero);
        return;
      }
      if (_queueIndex > 0 && _queueIndex - 1 < _queue.length) {
        _queueIndex = _queueIndex - 1;
        final prevTrack = _queue[_queueIndex];
        currentSong = prevTrack;
        notifyListeners();
        await playSong(prevTrack, queue: _queue);
      } else if (_queue.isNotEmpty) {
        await seek(Duration.zero);
      }
    } catch (e) {
      DebugLog.write('[player] previous error: $e');
    }
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

  /// Keep the notification's repeat / shuffle icons and playback state in sync with our state.
  void _publishNotificationState() {
    audioHandler?.updateState(
      playing: _player.playing,
      processingState: _player.processingState,
      position: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      loopMode: _loopMode,
      shuffle: _shuffle,
      queueIndex: _queueIndex >= 0 ? _queueIndex : null,
    );
  }

  Future<void> seek(Duration position) async {
    final dur = _player.duration;
    if (dur != null && dur > Duration.zero && position >= dur - const Duration(milliseconds: 150)) {
      await _player.seek(dur);
      if (!_isAdvancing && !_isLoadingTrack) {
        unawaited(next());
      } else {
        _pendingNaturalAdvance = true;
      }
      return;
    }
    await _player.seek(position);
  }

  Future<void> setVolume(double value) async {
    _userVolume = value.clamp(0.0, 1.0);
    await _player.setVolume(_userVolume);
    notifyListeners();
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
    _preloadDebounceTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}

