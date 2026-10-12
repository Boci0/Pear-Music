part of '../player_service.dart';

mixin _PlayerPreload on ChangeNotifier {
  // What the lookahead preloader needs from the player it is mixed into.
  AudioPlayer get _player;
  LibraryService get library;
  abstract Song? currentSong;
  abstract List<Song> _queue;
  abstract int _queueIndex;
  abstract bool _shuffle;
  abstract bool _autoplay;
  abstract LoopSetting _loopMode;
  abstract bool _autoRerollSeed;
  abstract Timer? _autoRerollDebounceTimer;
  abstract bool _isRerolling;
  abstract bool _isManuallyPaused;
  abstract bool _isLoadingTrack;
  abstract bool _isBufferingNext;
  abstract String? _bufferingVideoId;
  abstract bool _isPreloadingUpcoming;
  abstract bool _isLoadingRecommendations;
  abstract int _playRequestToken;
  void _levelNextSong();
  Future<bool> fetchAndAppendRecommendations();

  Timer? _preloadDebounceTimer;

  bool _isSongInLocalLibrary(String videoId) {
    for (final s in library.songs) {
      if ((RecommendationService.extractVideoId(s.fileName) == videoId ||
           RecommendationService.extractVideoId(s.id) == videoId) &&
          library.hasSongFile(s)) {
        return true;
      }
    }
    return false;
  }

  /// Kicks off a debounced 1-track lookahead preloader for the next stream
  /// track in the queue. Waits 2 seconds
  /// before initiating background download so rapid song skips consume 0 KB of data.
  // Called through the declarations in the recommendations and queue edit
  // mixins, which this one cannot build on (they need it too).
  // ignore: unused_element
  void _preloadUpcomingStreams({Duration delay = const Duration(seconds: 2)}) {
    _preloadDebounceTimer?.cancel();
    if (_queueIndex < 0 || _queue.isEmpty) {
      DebugLog.write('[preload] Skipping preload: queueIdx=$_queueIndex queueLen=${_queue.length}');
      return;
    }
    if (_autoRerollSeed && (_isRerolling || _autoRerollDebounceTimer != null)) {
      DebugLog.write('[preload] Auto-reroll option is ON (reroll active/pending); waiting for reroll before preloading');
      return;
    }
    const maxLookahead = 3;
    final upcomingVideoIds = <String>[];
    if (_shuffle) {
      for (int i = 0; i < _queue.length; i++) {
        if (i == _queueIndex) continue;
        final s = _queue[i];
        if (s.sourceDeviceId == 'stream') {
          final vId = RecommendationService.extractVideoId(s.id) ?? s.id.replaceFirst('stream_', '');
          if (vId.isNotEmpty && !upcomingVideoIds.contains(vId)) {
            upcomingVideoIds.add(vId);
            if (upcomingVideoIds.length >= maxLookahead) break;
          }
        }
      }
    } else {
      for (int idx = _queueIndex + 1; idx < _queue.length; idx++) {
        final s = _queue[idx];
        if (s.sourceDeviceId == 'stream') {
          final vId = RecommendationService.extractVideoId(s.id) ?? s.id.replaceFirst('stream_', '');
          if (vId.isNotEmpty && !upcomingVideoIds.contains(vId)) {
            upcomingVideoIds.add(vId);
            if (upcomingVideoIds.length >= maxLookahead) break;
          }
        }
      }
      if (upcomingVideoIds.length < maxLookahead && _loopMode == LoopSetting.all) {
        for (int idx = 0; idx <= _queueIndex; idx++) {
          final s = _queue[idx];
          if (s.sourceDeviceId == 'stream') {
            final vId = RecommendationService.extractVideoId(s.id) ?? s.id.replaceFirst('stream_', '');
            if (vId.isNotEmpty && !upcomingVideoIds.contains(vId)) {
              upcomingVideoIds.add(vId);
              if (upcomingVideoIds.length >= maxLookahead) break;
            }
          }
        }
      }
    }
    if (upcomingVideoIds.isEmpty) {
      if (_autoplay &&
          currentSong != null &&
          _queueIndex >= _queue.length - 1 &&
          !_isLoadingRecommendations) {
        DebugLog.write('[preload] Queue on last song with autoplay ON, pre-fetching recommendations...');
        unawaited(fetchAndAppendRecommendations());
      }
      DebugLog.write('[preload] No upcoming stream tracks to preload');
      _isPreloadingUpcoming = false;
      notifyListeners();
      return;
    }
    final uncachedTrackIds = upcomingVideoIds
        .where((id) => !StreamCacheManager.isStreamCachedSync(id) && !_isSongInLocalLibrary(id))
        .toList();
    if (uncachedTrackIds.isEmpty) {
      DebugLog.write('[preload] All upcoming stream tracks already cached on disk');
      _isPreloadingUpcoming = false;
      notifyListeners();
      return;
    }
    final nextTrackId = uncachedTrackIds.first;

    final token = _playRequestToken;
    _preloadDebounceTimer = Timer(delay, () {
      if (token != _playRequestToken) return;
      if (_isManuallyPaused || (!_player.playing && !_isLoadingTrack)) {
        DebugLog.write('[preload] Playback is paused or idle; skipping upcoming stream preload');
        _isPreloadingUpcoming = false;
        notifyListeners();
        return;
      }
      if (_isRerolling || _isLoadingRecommendations || (_autoRerollSeed && _autoRerollDebounceTimer != null)) {
        DebugLog.write('[preload] Reroll or recommendation in progress; deferring preload until settled');
        _preloadDebounceTimer = Timer(const Duration(milliseconds: 500), () {
          if (token == _playRequestToken) {
            _preloadUpcomingStreams(delay: Duration.zero);
          }
        });
        return;
      }
      if (_isBufferingNext || _bufferingVideoId != null || StreamCacheManager.isForegroundDownloadActive) {
        DebugLog.write('[preload] Current track is still downloading/buffering; deferring preload until completion');
        final activeId = StreamCacheManager.activeDownloadingVideoId;
        final inFlight = activeId != null ? StreamCacheManager.getInFlightDownload(activeId) : null;
        if (inFlight != null) {
          inFlight.whenComplete(() {
            if (token == _playRequestToken) {
              _preloadUpcomingStreams(delay: const Duration(milliseconds: 300));
            }
          });
        } else {
          _preloadDebounceTimer = Timer(const Duration(seconds: 1), () {
            if (token == _playRequestToken) {
              _preloadUpcomingStreams(delay: Duration.zero);
            }
          });
        }
        return;
      }
      DebugLog.write(
        '[preload] Starting 2-track sequential lookahead preloader: window=${uncachedTrackIds.take(2).toList()}',
      );
      _isPreloadingUpcoming = true;
      notifyListeners();

      // Sequential 2-track lookahead window: buffers upcoming tracks in the background
      // without splitting bandwidth, guaranteeing 0ms latency even on multi-skips.
      final nextTrackWindow = uncachedTrackIds.take(2).toList();
      StreamCacheManager.preloadSlidingWindow(
        nextTrackWindow,
        onTrackCached: (cachedId) {
          DebugLog.write('[preload] onTrackCached: $cachedId');
          _levelNextSong();
          if (cachedId == nextTrackId) {
            _isPreloadingUpcoming = false;
            notifyListeners();
          }
        },
        onDone: () {
          if (_isPreloadingUpcoming) {
            _isPreloadingUpcoming = false;
            notifyListeners();
          }
        },
      );
    });
  }
}
