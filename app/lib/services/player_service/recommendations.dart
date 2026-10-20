part of '../player_service.dart';

mixin _PlayerRecommendations on ChangeNotifier {
  // What radio, recommendations and rerolls need from the player they are
  // mixed into.
  AudioPlayer get _player;
  LibraryService get library;
  abstract Song? currentSong;
  abstract String? queueSourceId;
  abstract String? queueTitle;
  abstract List<Song> _queue;
  abstract int _queueIndex;
  abstract bool _isAdvancing;
  abstract bool _isLoadingTrack;
  abstract bool _isBufferingNext;
  abstract bool _isManuallyPaused;
  abstract bool _isLoadingRecommendations;
  abstract bool _isRerolling;
  abstract String? _continuationToken;
  abstract int _playRequestToken;
  set _lastInteraction(DateTime value);
  Set<String> get _autoAddedSongIds;
  Set<String> get _lockedSongIds;
  bool get playing;
  void _preloadUpcomingStreams({Duration delay = const Duration(seconds: 2)});
  void _syncQueueIndexWithCurrentSong();
  void _updateActiveQueueCacheProtection();
  void _resetAbandonedLoad();
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    String? sourceId,
    String? sourceTitle,
    int? requestToken,
    int? initialIndex,
    bool userInitiated = true,
  });

  /// Starts an infinite radio mix based on [seedSong].
  /// If [seedSong] is already playing, playback continues uninterrupted at the current position.
  Future<void> startRadio(Song seedSong) async {
    // A second start for the song whose radio is still loading (a double
    // click) would cancel that load and skip its own, leaving the player on
    // "connecting" with no sound.
    if (queueSourceId == 'radio' &&
        currentSong?.id == seedSong.id &&
        (_isLoadingTrack || _isBufferingNext)) {
      return;
    }
    _lastInteraction = DateTime.now();
    _continuationToken = null;
    _isLoadingRecommendations = false;
    _recommendationsCompleter = null;
    queueSourceId = 'radio';
    queueTitle = 'Radio (${seedSong.title})';

    final isAlreadyPlayingSeed = currentSong?.id == seedSong.id &&
        (_player.playing || _player.processingState != ProcessingState.idle);

    _queue = [seedSong];
    _queueIndex = 0;
    currentSong = seedSong;
    notifyListeners();

    // Allocate session token once so recommendation fetching and track playback
    // participate in the exact same active session without invalidating each other.
    final token = ++_playRequestToken;

    // A load cut short by the new token never reaches its own cleanup (see
    // PlayerService.stop), and this session keeps the current audio, so the
    // abandoned attempt is cancelled and its flags are reset here. Otherwise
    // the player could stay "loading" with no playback ever starting.
    _resetAbandonedLoad();

    // Trigger initial background fetch of recommended tracks
    unawaited(() async {
      final firstOk = await fetchAndAppendRecommendations();
      if (firstOk && _queue.length < 25) {
        await fetchAndAppendRecommendations();
      }
      if (!_isLoadingTrack && !_isAdvancing && !_isRerolling) {
        _preloadUpcomingStreams();
      }
    }());

    if (!isAlreadyPlayingSeed) {
      await playSong(
        seedSong,
        sourceId: 'radio',
        sourceTitle: queueTitle,
        requestToken: token,
      );
    }
  }

  Completer<bool>? _recommendationsCompleter;

  /// Fetches the next batch of recommendations and appends them to [_queue].
  Future<bool> fetchAndAppendRecommendations() async {
    if (_isLoadingRecommendations) {
      if (_recommendationsCompleter != null) {
        return await _recommendationsCompleter!.future;
      }
      return false;
    }
    if (_queue.isEmpty) return false;
    _isLoadingRecommendations = true;
    final completer = Completer<bool>();
    _recommendationsCompleter = completer;
    notifyListeners();

    try {
      final token = _playRequestToken;
      final excludeIds = RecommendationService.normalizeVideoIds(_queue.map((s) => s.id));
      final seed = currentSong ?? _queue.last;
      final seedId = seed.id;
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

      if (token != _playRequestToken || currentSong?.id != seedId) {
        DebugLog.write('[radio] Recommendations discarded: session changed during fetch (token=$token vs $_playRequestToken)');
        completer.complete(false);
        return false;
      }

      if (batch.items.isNotEmpty) {
        _continuationToken = batch.continuationToken;
        final existingVideoIds = RecommendationService.normalizeVideoIds(_queue.map((s) => s.id));
        final existingTitles = _queue.map((s) => s.title.toLowerCase().trim()).toSet();

        final newSongs = <Song>[];
        for (final item in batch.items) {
          if (newSongs.length >= PlayerService.maxRecommendationsPerAppend) break;
          if (existingVideoIds.contains(item.videoId)) continue;
          final cleanSong = item.toSong();
          final cleanTitle = cleanSong.title.toLowerCase().trim();
          if (existingTitles.contains(cleanTitle)) continue;

          existingVideoIds.add(item.videoId);
          existingTitles.add(cleanTitle);
          newSongs.add(cleanSong);
        }

        if (newSongs.isNotEmpty) {
          _autoAddedSongIds.addAll(newSongs.map((s) => s.id));
          _queue = [..._queue, ...newSongs];
          _syncQueueIndexWithCurrentSong();
          _updateActiveQueueCacheProtection();
          if (!_isLoadingTrack && !_isAdvancing && !_isRerolling && !_isManuallyPaused && playing) {
            _preloadUpcomingStreams();
          }
          DebugLog.write('[radio] Appended ${newSongs.length} unique tracks (queue size: ${_queue.length})');
          notifyListeners();
          completer.complete(true);
          return true;
        }
      }

      // Offline / Empty fallback: pull from local library
      // Library songs are matched by their own ids, which the video-id
      // normalisation above may have rewritten.
      final offlineSongs = RecommendationService.getOfflineRecommendations(
        seed,
        library.songs,
        excludeSongIds: {...excludeIds, ..._queue.map((s) => s.id)},
      );
      final boundedOffline = offlineSongs.take(PlayerService.maxRecommendationsPerAppend).toList();
      if (boundedOffline.isNotEmpty) {
        if (token != _playRequestToken || currentSong?.id != seedId) {
          completer.complete(false);
          return false;
        }
        _autoAddedSongIds.addAll(boundedOffline.map((s) => s.id));
        _queue = [..._queue, ...boundedOffline];
        _syncQueueIndexWithCurrentSong();
        _updateActiveQueueCacheProtection();
        DebugLog.write('[radio] Appended ${boundedOffline.length} offline library recommendations');
        notifyListeners();
        completer.complete(true);
        return true;
      }
      completer.complete(false);
      return false;
    } catch (e) {
      DebugLog.write('[radio] fetchAndAppendRecommendations error: $e');
      if (!completer.isCompleted) completer.complete(false);
      return false;
    } finally {
      _isLoadingRecommendations = false;
      _recommendationsCompleter = null;
      notifyListeners();
    }
  }

  /// Rerolls upcoming recommendations in the queue (songs after current song).
  /// Preserves any tracks explicitly marked as locked in the upcoming queue.
  /// Bounded to at most [PlayerService.maxRecommendationsPerAppend] (10 songs) to prevent
  /// bloating the queue.
  Future<bool> rerollUpcomingQueue({int? maxCount}) async {
    if (currentSong == null || _queue.isEmpty) return false;
    if (_isLoadingRecommendations) return false;
    _isLoadingRecommendations = true;
    notifyListeners();

    try {
      final token = _playRequestToken;
      _syncQueueIndexWithCurrentSong();
      final activeIndex = _queueIndex >= 0 ? _queueIndex : 0;
      final head = _queue.sublist(0, activeIndex + 1);
      final upcoming = _queue.length > activeIndex + 1 ? _queue.sublist(activeIndex + 1) : <Song>[];
      final lockedUpcoming = upcoming.where((s) => _lockedSongIds.contains(s.id)).toList();
      final unlockedUpcomingCount = upcoming.length - lockedUpcoming.length;
      final targetCount = maxCount ??
          (unlockedUpcomingCount > 0 ? unlockedUpcomingCount : PlayerService.maxRecommendationsPerAppend)
              .clamp(1, PlayerService.maxRecommendationsPerAppend);

      // Reset continuation token so we query fresh recommendations
      _continuationToken = null;

      final excludeIds = RecommendationService.normalizeVideoIds([
        ...head.map((s) => s.id),
        ...lockedUpcoming.map((s) => s.id),
      ]);

      final seed = currentSong ?? head.last;
      final seedId = seed.id;
      DebugLog.write(
          '[radio] Rerolling seed for "${seed.title}" (target: $targetCount, preserving ${lockedUpcoming.length} locked tracks)');

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

      if (token != _playRequestToken || currentSong?.id != seedId) {
        DebugLog.write('[radio] Reroll discarded: playback session changed during fetch');
        return false;
      }

      final freshSongs = <Song>[];
      if (batch.items.isNotEmpty) {
        _continuationToken = batch.continuationToken;
        final existingVideoIds = excludeIds.toSet();
        final existingTitles = {
          ...head.map((s) => s.title.toLowerCase().trim()),
          ...lockedUpcoming.map((s) => s.title.toLowerCase().trim()),
        };

        for (final item in batch.items) {
          if (freshSongs.length >= targetCount) break;
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
        freshSongs.addAll(offline.take(targetCount));
      }

      if (token != _playRequestToken || currentSong?.id != seedId) {
        return false;
      }

      _syncQueueIndexWithCurrentSong();
      final currentActiveIndex = _queueIndex >= 0 ? _queueIndex : 0;
      final currentHead = _queue.sublist(0, currentActiveIndex + 1);
      final currentUpcoming = _queue.length > currentActiveIndex + 1 ? _queue.sublist(currentActiveIndex + 1) : <Song>[];
      final currentLockedUpcoming = currentUpcoming.where((s) => _lockedSongIds.contains(s.id)).toList();

      _autoAddedSongIds.addAll(freshSongs.map((s) => s.id));
      _queue = [...currentHead, ...currentLockedUpcoming, ...freshSongs];
      _syncQueueIndexWithCurrentSong();
      _updateActiveQueueCacheProtection();
      if (!_isLoadingTrack && !_isAdvancing && !_isManuallyPaused && playing) {
        _preloadUpcomingStreams();
      }
      DebugLog.write(
          '[radio] Reroll complete: queue now has ${_queue.length} tracks (${currentLockedUpcoming.length} locked, ${freshSongs.length} new)');
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

  /// Auto-rerolls the single next track following the current song, and immediately
  /// caches it in the background so it is instantly ready when the current track finishes.
  Future<bool> rerollNextTrackOnly() async {
    if (currentSong == null || _queue.isEmpty || _isRerolling) return false;
    _isRerolling = true;
    if (_isLoadingRecommendations) {
      _isRerolling = false;
      return false;
    }
    _isLoadingRecommendations = true;
    notifyListeners();
    bool changed = false;

    try {
      final token = _playRequestToken;
      _syncQueueIndexWithCurrentSong();
      final activeIndex = _queueIndex >= 0 ? _queueIndex : 0;
      final head = _queue.sublist(0, activeIndex + 1);
      final upcoming = _queue.length > activeIndex + 1
          ? _queue.sublist(activeIndex + 1)
          : <Song>[];

      // If upcoming is empty, there is no next track to replace.
      // Auto-reroll does not add new tracks; expanding the queue only happens
      // when at the end of queue and autoplay is ON.
      if (upcoming.isEmpty) {
        return false;
      }

      final oldNextSong = upcoming.first;
      if (_lockedSongIds.contains(oldNextSong.id)) {
        // The next track is locked; do not replace it.
        return false;
      }

      final tail = upcoming.sublist(1);

      final excludeIds = RecommendationService.normalizeVideoIds([
        ...head.map((s) => s.id),
        oldNextSong.id,
        ...tail.map((s) => s.id),
      ]);

      final seed = currentSong ?? head.last;
      final seedId = seed.id;
      DebugLog.write(
          '[radio] Auto-rerolling next track for "${seed.title}" (preserving ${tail.length} following tracks)');

      RecommendationBatch batch;
      try {
        batch = await RecommendationService.fetchRadio(
          seed,
          excludeVideoIds: excludeIds,
        );
      } catch (e) {
        DebugLog.write(
            '[radio] Online reroll error ($e), falling back to offline library');
        batch = const RecommendationBatch(items: []);
      }

      if (token != _playRequestToken || currentSong?.id != seedId) {
        DebugLog.write('[radio] Auto-reroll discarded: playback session changed during fetch');
        return false;
      }

      Song? nextSong;
      if (batch.items.isNotEmpty) {
        final existingVideoIds = excludeIds.toSet();
        final existingTitles = {
          ...head.map((s) => s.title.toLowerCase().trim()),
          oldNextSong.title.toLowerCase().trim(),
          ...tail.map((s) => s.title.toLowerCase().trim()),
        };

        for (final item in batch.items) {
          if (existingVideoIds.contains(item.videoId)) continue;
          final cleanSong = item.toSong();
          final cleanTitle = cleanSong.title.toLowerCase().trim();
          if (existingTitles.contains(cleanTitle)) continue;

          nextSong = cleanSong;
          break;
        }
      }

      if (nextSong == null) {
        final offlineExcludeIds = {
          ...head.map((s) => s.id),
          oldNextSong.id,
          ...tail.map((s) => s.id),
        };
        final offline = RecommendationService.getOfflineRecommendations(
          seed,
          library.songs,
          excludeSongIds: offlineExcludeIds,
        );
        if (offline.isNotEmpty) {
          nextSong = offline.first;
        }
      }

      if (token != _playRequestToken || currentSong?.id != seedId) {
        return false;
      }

      if (nextSong != null) {
        _syncQueueIndexWithCurrentSong();
        final currentActiveIndex = _queueIndex >= 0 ? _queueIndex : 0;
        final currentHead = _queue.sublist(0, currentActiveIndex + 1);
        final currentUpcoming = _queue.length > currentActiveIndex + 1
            ? _queue.sublist(currentActiveIndex + 1)
            : <Song>[];
        if (currentUpcoming.isEmpty ||
            currentUpcoming.first.id != oldNextSong.id ||
            _lockedSongIds.contains(currentUpcoming.first.id)) {
          DebugLog.write(
              '[radio] Auto-reroll discarded: next track was modified or locked during fetch');
          return false;
        }
        final currentTail = currentUpcoming.sublist(1);

        _autoAddedSongIds.add(nextSong.id);
        _queue = [...currentHead, nextSong, ...currentTail];
        _syncQueueIndexWithCurrentSong();
        _updateActiveQueueCacheProtection();
        DebugLog.write(
            '[radio] Auto-reroll changed next track: "${oldNextSong.title}" -> "${nextSong.title}". Queue length remains ${_queue.length}.');
        changed = true;
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      DebugLog.write('[radio] rerollNextTrackOnly error: $e');
      return false;
    } finally {
      _isLoadingRecommendations = false;
      _isRerolling = false;
      notifyListeners();
      if (changed) {
        final nextS =
            _queue.length > _queueIndex + 1 ? _queue[_queueIndex + 1] : null;
        if (nextS != null && nextS.sourceDeviceId == 'stream') {
          final vId = RecommendationService.extractVideoId(nextS.id) ??
              nextS.id.replaceFirst('stream_', '');
          DebugLog.write(
              '[radio] Scheduling preload for settled rerolled track: $vId');
        }
        _preloadUpcomingStreams(delay: Duration.zero);
      }
    }
  }
}
