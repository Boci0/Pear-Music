part of '../player_service.dart';

mixin _PlayerPlayback
    on
        ChangeNotifier,
        _PlayerCrossfade,
        _PlayerLive,
        _PlayerRecommendations,
        _PlayerPreload,
        _PlayerQueueEdit {
  // What playback and the transport controls need from the player they are
  // mixed into (the rest comes from the mixins above).
  DateTime get _lastInteraction;
  abstract int _consecutiveStreamFailures;
  set _currentLoadedFileSize(int? value);
  set _currentLoadedFormat(String? value);
  set _currentRouteType(StreamRouteType value);
  abstract GrowingFileAudioSource? _growingSource;
  abstract String? _lastAutoRerolledSongId;
  abstract int _lastTrackLoadMs;
  void _levelSong(Song song, int token, Future<File?>? pendingDownload);
  void _maybeCompactMemory();
  bool get _nextIsAutoRerollable;
  void _notifyUser(String message);
  abstract bool _pendingNaturalAdvance;
  abstract PlaybackError? _playbackError;
  // ignore: unused_element_parameter
  abstract Timer? _saveVolumeDebounceTimer;
  void _setPlaybackError(PlaybackError error);
  set _songGain(double value);
  void _syncEngineLoop();
  abstract double _userVolume;
  PearAudioHandler? get audioHandler;
  void cancelSleepTimer();
  void clearPlaybackError({bool notify = true});
  HistoryService? get history;
  ValueNotifier<double> get volumeNotifier;

  /// Plays a live stream from its HLS link; it never ends, so it is never
  /// cached. False when no link resolved or it would not open. True when a
  /// newer play request took over meanwhile, so the caller just stops.
  Future<bool> _playLiveStream(
    Song song,
    String videoId,
    int token,
    Stopwatch stopwatch,
  ) async {
    final link = await StreamCacheManager.resolveLiveLink(videoId);
    if (token != _playRequestToken) return true;
    if (link == null) return false;
    try {
      // Every platform plays one continuous local stream, not the playlist:
      // the desktop engine cannot play it at all (it would end the "song"
      // after each five-second segment), and the phone's player re-reads the
      // 900 KB playlist uncompressed every few seconds, which measured about
      // 230 KB/s (13 MB a minute) of mobile data against about 20 KB/s here.
      final source = AudioSource.uri(await LiveHlsProxy.serve(
        link.url,
        refresh: () async =>
            (await StreamCacheManager.resolveLiveLink(videoId))?.url,
      ));
      await _player.setAudioSource(source).timeout(PlayerService._earlyStreamOpenTimeout);
    } catch (e) {
      DebugLog.write('[player] Live stream $videoId would not play: $e');
      return token != _playRequestToken;
    }
    if (token != _playRequestToken) return true;
    _currentRouteType = StreamRouteType.direct;
    _lastTrackLoadMs = stopwatch.elapsedMilliseconds;
    _currentLoadedFile = null;
    _currentLoadedFileSize = null;
    _currentLoadedFormat = 'hls';
    _isLive = true;
    _liveBehind = 0;
    _livePausedSince = null;
    _resetStreamFailureCounters();
    notifyListeners();
    DebugLog.write('[player] LIVE (${_lastTrackLoadMs}ms): "${song.title}" [$videoId]');
    return true;
  }

  /// Logs [song] as played. Stream songs are also registered as known online
  /// songs so the history row can still resolve its title/artwork later (they
  /// are not in the library until the user saves them).
  void _recordHistory(Song song) {
    final log = history;
    if (log == null) return;
    final id = identity;
    if (id != null && song.sourceDeviceId == 'stream') {
      unawaited(id.registerOnlineSong(song));
    }
    log.record(song);
  }

  /// Play [song], optionally in the context of [queue] (e.g. a playlist).
  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    String? sourceId,
    String? sourceTitle,
    int? requestToken,
    int? initialIndex,
    bool userInitiated = true,
  }) async {
    // Songs that start on their own (autoplay, the end of a song) do not
    // count as the listener being around, or the inactivity guard in [next]
    // could never pause an all-night autoplay.
    if (userInitiated) _lastInteraction = DateTime.now();
    final crossfadeIn = _pendingFadeIn;
    final fadeIn = crossfadeIn ?? const Duration(milliseconds: 80);
    if (_pendingFadeIn == null) _silenceTail();
    _pendingFadeIn = null;
    if (identity != null && identity!.isFavorite(song.id)) {
      unawaited(identity!.cacheFavoriteSongMetadata(song));
    }
    final token = requestToken ?? ++_playRequestToken;
    _isManuallyPaused = false;
    _pendingNaturalAdvance = false;
    clearPlaybackError(notify: false);
    _preloadDebounceTimer?.cancel();
    _isAdvancing = true;
    _isLoadingTrack = true;

    // Immediately mute and pause existing playback so the previous track does not
    // produce an audio pop, crackle, or continue playing while the new track is resolving.
    if (_player.playing) {
      await _player.setVolume(0.0);
      await _player.pause();
    }
    // A pause (or a newer play) that lands while the previous source is being
    // silenced wins over this request; nothing below has been changed yet.
    if (token != _playRequestToken) return;

    // The request still owns the session, so it counts as a play for history
    // and radio exclusions. Superseded taps are excluded above; this keeps the
    // same observable point in playSong as recording it before the load.
    RecommendationService.markPlayed(song.id);
    _recordHistory(song);

    // Android 13+ blocks the media notification unless the app holds the
    // notification permission. Ask for it (fire-and-forget) so the first
    // play shows the notification; the prompt does not delay playback.
    _requestNotificationPermissionIfNeeded();

    if (queue != null) {
      // A queue the listener just picked (not this queue handed back when
      // moving along it) starts with nothing added by the app, and starts
      // shuffle over: ids played in the old queue are not part of this one.
      if (!identical(queue, _queue)) {
        _autoAddedSongIds.clear();
        _shufflePlayedSongIds.clear();
      }
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
    if (initialIndex != null &&
        initialIndex >= 0 &&
        initialIndex < _queue.length &&
        _queue[initialIndex].id == song.id) {
      _queueIndex = initialIndex;
    } else {
      _queueIndex = _queue.indexWhere((s) => s.id == song.id);
    }
    if (_queueIndex < 0) {
      _queue = [song, ..._queue];
      _queueIndex = 0;
    }
    if (_shuffle) {
      _shufflePlayedSongIds.add(song.id);
    }
    currentSong = song;
    _pendingNaturalAdvance = false;
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
      final optimized = ArtworkService.optimizeArtworkUrl(song.artwork!);
      effectiveArtUri = Uri.tryParse(optimized) ??
          Uri.tryParse(song.artwork!) ??
          await ArtworkService.defaultArtworkUri();
    } else {
      effectiveArtUri = await ArtworkService.songArtworkUri(song).timeout(
        const Duration(milliseconds: 150),
        onTimeout: () => ArtworkService.defaultArtworkUri(),
      );
    }
    if (token != _playRequestToken) return;
    // The player still holds the previous song here, so its length is not
    // passed on: the new song's arrives once it has loaded.
    audioHandler?.updateSongMediaItem(song, artUri: effectiveArtUri);

    final stopwatch = Stopwatch()..start();
    _isLive = false;
    Future<File?>? pendingDownload;
    final previousGrowing = _growingSource;
    _growingSource = null;
    if (previousGrowing != null) unawaited(previousGrowing.close());
    try {
      await _player.setLoopMode(_engineLoopMode);
      if (token != _playRequestToken) return;

      if (song.sourceDeviceId == 'stream') {
        final videoId = RecommendationService.extractVideoId(song.id) ?? song.id.replaceFirst('stream_', '');
        DebugLog.write('[player] Stream path: checking active preload for $videoId');
        StreamCacheManager.cancelPreload(exceptVideoId: videoId);
        StreamCacheManager.cancelActiveDownload(exceptVideoId: videoId);
        DebugLog.write('[player] Resolved videoId=$videoId, checking disk cache...');

        File? cachedFile = await StreamCacheManager.getCachedFile(videoId);
        if (cachedFile != null) unawaited(StreamCacheManager.markPlayed(cachedFile));
        if (cachedFile == null) {
          for (final s in library.songs) {
            if ((RecommendationService.extractVideoId(s.fileName) == videoId ||
                 RecommendationService.extractVideoId(s.id) == videoId) &&
                library.hasSongFile(s)) {
              final file = library.songFile(s);
              if (await file.exists()) {
                cachedFile = file;
                DebugLog.write('[player] Found local library audio for $videoId: ${file.path}');
                break;
              }
            }
          }
        }
        if (token != _playRequestToken) return;

        if (cachedFile != null && await cachedFile.exists()) {
          _currentRouteType = StreamRouteType.cached;
          _lastTrackLoadMs = stopwatch.elapsedMilliseconds;
          _currentLoadedFile = cachedFile;
          _currentLoadedFileSize = await cachedFile.length();
          _currentLoadedFormat = p.extension(cachedFile.path).replaceFirst('.', '');
          _isBufferingNext = false;
          _bufferingVideoId = null;
          notifyListeners();
          DebugLog.write('[player] DISK CACHE HIT (${_lastTrackLoadMs}ms): "${song.title}" [$videoId] file=${cachedFile.path}');
          try {
            await _player.setAudioSource(
              AudioSource.file(cachedFile.path),
            );
            _resetStreamFailureCounters();
          } on PlayerInterruptedException {
            // A newer load took over the engine: the file is fine, so keep
            // it in the cache and let the outer handler drop this request.
            DebugLog.write('[player] Cached file load was superseded; keeping it in the cache');
            rethrow;
          } catch (e) {
            DebugLog.write('[player] Cached file unplayable or corrupt: $e. Evicting from cache.');
            await StreamCacheManager.evictUnplayable(cachedFile);
            rethrow;
          }
        } else {
          // Signal buffering state so the UI shows "Connecting to Pear Radio..."
          _isBufferingNext = true;
          _bufferingVideoId = videoId;
          notifyListeners();

          DebugLog.write('[player] DISK CACHE MISS for $videoId, downloading via ensureStreamCached...');

          // Play while it downloads: the desktop fetch reports the direct
          // audio link as soon as it has picked a format, so playback starts
          // from that link instead of waiting for the whole file. The same
          // fetch keeps filling the cache for the next play. If the link
          // never arrives (Android, early failure) or will not play, this
          // falls back to waiting for the cached file as before.
          final linkReady = Completer<ResolvedStream?>();
          final download = StreamCacheManager.ensureStreamCached(
            videoId,
            onStreamUrl: (stream) {
              if (!linkReady.isCompleted) linkReady.complete(stream);
            },
          );
          pendingDownload = download;
          unawaited(download.then(
            (_) {
              if (!linkReady.isCompleted) linkReady.complete(null);
            },
            onError: (_) {
              if (!linkReady.isCompleted) linkReady.complete(null);
            },
          ));
          final link = await linkReady.future;
          if (token != _playRequestToken) return;
          var streaming = false;
          if (link != null) {
            // Android hands over the file being written (YouTube blocks the
            // phone's player from the link itself); desktop streams the link.
            final localPath = link.localPath;
            final growing = localPath == null
                ? null
                : GrowingFileAudioSource(
                    path: localPath,
                    done: download.then((_) {}, onError: (_) {}),
                    expectedLength: link.filesize,
                    contentType: link.ext == 'webm' ? 'audio/webm' : 'audio/mp4',
                  );
            try {
              // A link that was already used up or throttled (HTTP 403) can
              // leave the player opening it forever, which kept the song on
              // "loading" with no error. Give up and use the cached file.
              final opening = _player
                  .setAudioSource(
                    growing ??
                        AudioSource.uri(Uri.parse(link.url),
                            headers: link.headers),
                  )
                  .timeout(PlayerService._earlyStreamOpenTimeout);
              // A fetch that ends with no file (a 403, a dropped connection)
              // leaves the engine retrying an empty source for seconds before
              // it reports an error. Once the fetch itself is over with
              // nothing to play, stop waiting and go straight to the retry.
              final fetchEndedEmpty = Completer<void>();
              unawaited(download.then(
                (file) {
                  if (file == null && !fetchEndedEmpty.isCompleted) {
                    fetchEndedEmpty.complete();
                  }
                },
                onError: (_) {
                  if (!fetchEndedEmpty.isCompleted) fetchEndedEmpty.complete();
                },
              ));
              await Future.any<void>([
                opening,
                fetchEndedEmpty.future.then(
                  (_) => throw StateError('the fetch ended without a file'),
                ),
              ]);
              if (token != _playRequestToken) {
                if (growing != null) unawaited(growing.close());
                return;
              }
              _growingSource = growing;
              _isBufferingNext = false;
              _bufferingVideoId = null;
              _currentRouteType = StreamRouteType.direct;
              _lastTrackLoadMs = stopwatch.elapsedMilliseconds;
              _currentLoadedFile = null;
              _currentLoadedFileSize = null;
              _currentLoadedFormat = link.ext;
              _resetStreamFailureCounters();
              streaming = true;
              notifyListeners();
              DebugLog.write(
                '[player] STREAMING while caching (${_lastTrackLoadMs}ms): "${song.title}" [$videoId]',
              );
              // Only the success is used; the fetch keeps caching the file.
              unawaited(download.catchError((_) => null));
            } catch (e) {
              if (growing != null) unawaited(growing.close());
              DebugLog.write(
                '[player] Early stream would not play ($e); waiting for the cached file instead',
              );
            }
          }
          File? downloadedFile = streaming ? null : await download;

          // Retry once after short delay if initial resolution returned null
          if (!streaming &&
              downloadedFile == null &&
              !StreamCacheManager.isKnownLive(videoId) &&
              token == _playRequestToken) {
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

          if (streaming) {
            // Already playing from the direct link; the file is still caching.
          } else if (downloadedFile != null && await downloadedFile.exists()) {
            _currentRouteType = StreamRouteType.direct;
            _lastTrackLoadMs = stopwatch.elapsedMilliseconds;
            _currentLoadedFile = downloadedFile;
            _currentLoadedFileSize = await downloadedFile.length();
            _currentLoadedFormat = p.extension(downloadedFile.path).replaceFirst('.', '');
            notifyListeners();
            DebugLog.write('[player] DOWNLOADED OK (${_lastTrackLoadMs}ms): "${song.title}" [$videoId] file=${downloadedFile.path} size=${await downloadedFile.length()} bytes');
            try {
              await _player.setAudioSource(
                AudioSource.file(downloadedFile.path),
              );
              _resetStreamFailureCounters();
            } on PlayerInterruptedException {
              // A newer load took over the engine: the file is fine, so keep
              // it in the cache and let the outer handler drop this request.
              DebugLog.write('[player] Downloaded file load was superseded; keeping it in the cache');
              rethrow;
            } catch (e) {
              DebugLog.write('[player] Downloaded stream unplayable or corrupt: $e. Evicting file.');
              await StreamCacheManager.evictUnplayable(downloadedFile);
              rethrow;
            }
          } else if (StreamCacheManager.isKnownLive(videoId) &&
              await _playLiveStream(song, videoId, token, stopwatch)) {
            if (token != _playRequestToken) return;
          } else {
            _pendingNaturalAdvance = false;
            _consecutiveStreamFailures++;
            final failure = StreamCacheManager.takeFetchFailure(videoId);
            DebugLog.write(
              '[player] Stream failed for ${song.title} '
              '(failure $_consecutiveStreamFailures/3, '
              'kind=${failure?.kind.name ?? 'unknown'}, '
              'detail=${failure?.detail ?? 'n/a'})',
            );
            _isAdvancing = false;
            _isLoadingTrack = false;
            notifyListeners();

            final described = PlayerService.describeStreamFailure(failure, song);

            // A deleted/private video can never start playing, so skipping is
            // the only way forward. The skip stays bounded: three dead tracks
            // in a row stop playback instead of cascading through the queue.
            // Everything else (403 blocks, network trouble, missing engine)
            // stays on this track with an explanation and a retry, because it
            // usually works again a moment later.
            if (failure?.kind == StreamFetchFailureKind.unavailable &&
                _consecutiveStreamFailures < 3 &&
                _queue.length > 1) {
              DebugLog.write(
                '[player] Auto-advancing past unavailable stream "${song.title}"',
              );
              _notifyUser(described.message);
              unawaited(next());
              return;
            }

            _setPlaybackError(described);
            _notifyUser(described.message);
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
        DebugLog.write('[player] Playing LOCAL file (${_lastTrackLoadMs}ms): ${song.title}');
        final file = library.songFile(song);
        if (!await file.exists() || await file.length() == 0) {
          DebugLog.write('[player] File missing or empty on disk for ${song.title} (${file.path}). Pruning ghost song.');
          unawaited(library.removeSong(song.id));
          _pendingNaturalAdvance = false;
          _isLoadingTrack = false;
          _isAdvancing = false;
          removeSongsFromQueue({song.id});
          return;
        }
        _currentLoadedFile = file;
        _currentLoadedFileSize = await file.length();
        _currentLoadedFormat = p.extension(file.path).replaceFirst('.', '');
        notifyListeners();
        try {
          await _player.setAudioSource(
            AudioSource.file(file.path),
          );
        } catch (e) {
          // Never delete the song here. Failing to open a file says little about
          // the file: the audio backend may not have started, the output device
          // may be busy, or the file may be locked for a moment. Removing the
          // entry also deletes the user's copy, which cannot be undone, so the
          // song stays and the user is told, with a retry.
          DebugLog.write('[player] Could not open ${song.title} ($e). Keeping it in the library.');
          _pendingNaturalAdvance = false;
          _isLoadingTrack = false;
          _isAdvancing = false;
          final message = 'Couldn\'t play "${song.title}": the audio engine could not open the '
              'file. It is still in your library. Tap play to retry, or remove '
              'it yourself if it is damaged.';
          _setPlaybackError(PlaybackError(
            song: song,
            label: 'Couldn\'t open this file. Tap play to retry.',
            message: message,
          ));
          _notifyUser(message);
          notifyListeners();
          return;
        }
      }

      if (token != _playRequestToken) {
        DebugLog.write('[player] Token stale before play() ($token != $_playRequestToken), aborting');
        return;
      }
      if ((_speed - 1.0).abs() > 0.01) {
        try {
          await _player.setSpeed(_speed);
        } catch (e) {
          DebugLog.write('[player] setSpeed failed: $e');
        }
      }
      _songGain = LoudnessService.startGainFor(song);
      final targetVol = _effectiveVolume;
      await _player.setVolume(0.0);
      final musicStart = _musicStartFor(song);
      if (musicStart > Duration.zero) {
        try {
          await _player.seek(musicStart);
        } catch (e) {
          DebugLog.write('[player] could not skip the silent intro: $e');
        }
      }
      unawaited(_player.play());
      _levelSong(song, token, pendingDownload);
      if (LoudnessService.isMeasured(song)) _levelNextSong();
      _maybeCompactMemory();
      if (targetVol > 0.01) {
        unawaited(crossfadeIn != null
            ? _fadeInOverTail(targetVol, crossfadeIn)
            : _fadeVolume(
                targetVol,
                duration: musicStart > Duration.zero ? _PlayerCrossfade._introFadeIn : fadeIn,
              ));
      }
      _isManuallyPaused = false;
      _isLoadingTrack = false;
      _isAdvancing = false;
      _consecutiveStreamFailures = 0;
      audioHandler?.updateSongDuration(song.id, _player.duration);
      _publishNotificationState();
      var willAutoReroll = false;
      if (_autoRerollSeed) {
        final hasUpcoming = _queueIndex < _queue.length - 1;
        // Only a next song the app picked (radio, or recommendations after
        // the listener's own queue ran out) is rerolled; playlists and
        // albums keep their order even when their songs stream.
        if (!hasUpcoming || _nextIsAutoRerollable) {
          if (song.id != _lastAutoRerolledSongId || !hasUpcoming) {
            _lastAutoRerolledSongId = song.id;
            willAutoReroll = true;
            _scheduleAutoReroll(token);
          }
        }
      }
      DebugLog.write('[player] === playSong SUCCESS === "${song.title}" queueIdx=$_queueIndex${willAutoReroll ? ", waiting for auto-reroll before preload" : ", triggering preload"}');
      if (!willAutoReroll) {
        _preloadUpcomingStreams(delay: const Duration(milliseconds: 500));
      }
    } catch (e) {
      DebugLog.write('[player] playSong ERROR: $e');
      if (e is PlayerInterruptedException) {
        // Another load took over the engine. That is a superseded request,
        // not a playback failure: no error banner and no failure count. Its
        // flags are cleared only while it still owns the token, so a newer
        // request's state is left alone.
        if (token == _playRequestToken) {
          _pendingNaturalAdvance = false;
          _isAdvancing = false;
          _isLoadingTrack = false;
          _isBufferingNext = false;
          _bufferingVideoId = null;
          notifyListeners();
        }
        return;
      }
      if (token != _playRequestToken) return;
      _pendingNaturalAdvance = false;
      _consecutiveStreamFailures++;
      _isAdvancing = false;
      _isLoadingTrack = false;
      final described = PlaybackError(
        song: song,
        label: 'Couldn\'t play this track. Tap play to retry.',
        message: 'Couldn\'t play "${song.title}". Tap play to retry.',
      );
      _setPlaybackError(described);
      _notifyUser(described.message);
      await _player.pause();
      notifyListeners();
    } finally {
      if (token == _playRequestToken) {
        _isAdvancing = false;
        _isLoadingTrack = false;
        _isBufferingNext = false;
        _bufferingVideoId = null;
        // The previous live stream's relay is stopped only now that this song
        // has its own source: stopping it earlier makes the player report the
        // old stream's end, about five seconds on, as a finished song.
        if (!_isLive) LiveHlsProxy.stop();
        if (_pendingNaturalAdvance) {
          _pendingNaturalAdvance = false;
          DebugLog.write('[player] Song in completed state during finally; auto-advancing next');
          if (_sleep.endOfSong) {
            cancelSleepTimer();
            unawaited(pause(smooth: true));
          } else {
            unawaited(next());
          }
        }
        notifyListeners();
      }
    }
  }

  /// Resets the player's consecutive-failure counter. Called after any
  /// successful playback.
  void _resetStreamFailureCounters() {
    if (_consecutiveStreamFailures > 0) {
      DebugLog.write('[player] Resetting stream failure counters (was $_consecutiveStreamFailures failures)');
    }
    _consecutiveStreamFailures = 0;
  }

  void _scheduleAutoReroll(int token) {
    _autoRerollDebounceTimer?.cancel();
    _autoRerollDebounceTimer = Timer(const Duration(milliseconds: 350), () async {
      _autoRerollDebounceTimer = null;
      if (token != _playRequestToken || !_autoRerollSeed || currentSong == null || _isRerolling) {
        return;
      }
      DebugLog.write('[radio] Auto-rerolling next track for "${currentSong!.title}"');
      // The queue may have changed since this was scheduled.
      final changed =
          _nextIsAutoRerollable ? await rerollNextTrackOnly() : false;
      if (!changed && token == _playRequestToken) {
        _preloadUpcomingStreams(delay: Duration.zero);
      }
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
    // A different list is a new shuffle pool: ids played in the previous
    // queue must not make songs of this one count as already played. An
    // identical list (same songs in the same order) keeps the shuffle history.
    var sameQueue = newQueue.length == _queue.length;
    if (sameQueue) {
      for (var i = 0; i < newQueue.length; i++) {
        if (newQueue[i].id != _queue[i].id) {
          sameQueue = false;
          break;
        }
      }
    }
    _queue = List.from(newQueue);
    if (!sameQueue) {
      _shufflePlayedSongIds.clear();
      if (_shuffle && currentSong != null) {
        _shufflePlayedSongIds.add(currentSong!.id);
      }
    }
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

  @override
  void _updateActiveQueueCacheProtection() {
    final vIds = <String>{};
    if (currentSong != null && currentSong!.sourceDeviceId == 'stream') {
      final vId = RecommendationService.extractVideoId(currentSong!.id) ?? currentSong!.id.replaceFirst('stream_', '');
      if (vId.isNotEmpty) vIds.add(vId);
    }
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
    _silenceTail();
    _isManuallyPaused = true;
    _playRequestToken++;
    _preloadDebounceTimer?.cancel();
    _preloadDebounceTimer = null;
    if (_isPreloadingUpcoming || StreamCacheManager.isActiveDownloadPreload) {
      StreamCacheManager.cancelPreload();
      _isPreloadingUpcoming = false;
    }
    if (_isLoadingTrack || _isBufferingNext) {
      _isLoadingTrack = false;
      _isBufferingNext = false;
      _bufferingVideoId = null;
      _isAdvancing = false;
      StreamCacheManager.cancelActiveDownload();
    }
    _publishNotificationState();
    notifyListeners();
    final targetVol = _effectiveVolume;
    if (_player.playing) {
      if (smooth && targetVol > 0.05) {
        try {
          await _fadeVolume(0.0, duration: const Duration(milliseconds: 100));
        } catch (e) {
          // A failure to fade must not leave the player audible: fall
          // through to the pause below.
          DebugLog.write('[player] pause fade failed: $e');
        }
      }
      await _player.pause();
      await _player.setVolume(targetVol);
    } else {
      await _player.setVolume(targetVol);
    }
    _publishNotificationState();
    notifyListeners();
  }

  Future<void> resume() async {
    _lastInteraction = DateTime.now();
    if (_isLoadingTrack || _isBufferingNext) {
      return;
    }
    if (currentSong == null) {
      if (library.songs.isNotEmpty) {
        await playSong(library.songs.first);
      }
      return;
    }
    // A failed load never produced a playable source, so the play button
    // doubles as "retry this track" while an error is on screen.
    if (_playbackError != null) {
      await retryCurrent();
      return;
    }
    _isManuallyPaused = false;
    _publishNotificationState();
    notifyListeners();

    if (_player.processingState == ProcessingState.completed) {
      if (currentSong != null) {
        await playSong(currentSong!, queue: _queue, sourceId: queueSourceId, sourceTitle: queueTitle);
        return;
      }
      await _player.seek(Duration.zero);
    }
    final pausedSince = _livePausedSince;
    if (_isLive &&
        pausedSince != null &&
        DateTime.now().difference(pausedSince) > PlayerService._liveReopenAfter) {
      final window = liveWindow;
      await _openLive(liveBehind.clamp(0.0, window > 0 ? window : liveBehind).toDouble());
    }
    final targetVol = _effectiveVolume;
    await _player.setVolume(targetVol);
    try {
      await _player.play();
      await _player.setVolume(targetVol);
      _resetStreamFailureCounters();
      _preloadUpcomingStreams(delay: const Duration(milliseconds: 500));
    } catch (e) {
      DebugLog.write('[player] resume failed ($e), reloading track: ${currentSong?.title}');
      if (currentSong != null) {
        await playSong(currentSong!);
      }
    }
    _publishNotificationState();
    notifyListeners();
  }

  /// Retries the track that failed last: clears the error state and runs a
  /// fresh load. When YouTube had blocked the request, yt-dlp's cached player
  /// is dropped first because a stale player is a common cause of 403s.
  Future<void> retryCurrent() async {
    final song = currentSong;
    if (song == null) return;
    _lastInteraction = DateTime.now();
    final wasBlocked = _playbackError?.kind == StreamFetchFailureKind.blocked;
    clearPlaybackError(notify: false);
    if (wasBlocked && song.sourceDeviceId == 'stream') {
      DebugLog.write('[player] Retrying blocked stream "${song.title}" with a fresh yt-dlp player cache');
      await StreamCacheManager.refreshYtDlpCache();
    }
    notifyListeners();
    await playSong(
      song,
      queue: _queue.isEmpty ? null : _queue,
      sourceId: queueSourceId,
      sourceTitle: queueTitle,
      initialIndex:
          _queueIndex >= 0 && _queueIndex < _queue.length ? _queueIndex : null,
    );
  }

  Future<void> toggle() async {
    _lastInteraction = DateTime.now();
    if (_isLoadingTrack || _isBufferingNext) {
      DebugLog.write('[player] toggle() tapped while audio is buffering; cancelling load and pausing');
      _playRequestToken++;
      _isLoadingTrack = false;
      _isBufferingNext = false;
      _bufferingVideoId = null;
      _isAdvancing = false;
      _isManuallyPaused = true;
      StreamCacheManager.cancelActiveDownload();
      StreamCacheManager.cancelPreload();
      await _player.pause();
      _publishNotificationState();
      notifyListeners();
      return;
    }
    if (currentSong == null) {
      if (library.songs.isNotEmpty) {
        await playSong(library.songs.first);
      }
      return;
    }
    DebugLog.write('[player] toggle() called: playing=$playing, isManuallyPaused=$_isManuallyPaused');
    if (playing) {
      await pause(smooth: false);
    } else {
      await resume();
    }
  }

  @override
  Future<void> next({bool userAction = false, bool crossfade = false}) async {
    if (userAction) {
      _lastInteraction = DateTime.now();
    }
    if (_queue.isEmpty || _isAdvancing) {
      if (crossfade) {
        // Nothing to hand over to: keep the song going on the main player.
        _silenceTail();
        unawaited(_player.setVolume(_effectiveVolume));
      }
      return;
    }
    _isAdvancing = true;
    final advanceToken = _playRequestToken;
    try {
      if (!crossfade && _player.playing && _userVolume > 0.05) {
        await _fadeVolume(0.0, duration: const Duration(milliseconds: 80));
        // A pause (which bumps the token) or a newer play during the fade
        // wins over this advance: stay on the current track and hand the
        // listener their volume back.
        if (advanceToken != _playRequestToken) {
          if (_player.playing && _player.volume < _effectiveVolume) {
            unawaited(_player.setVolume(_effectiveVolume));
          }
          return;
        }
      }
      if (_loopMode == LoopSetting.one && !userAction) {
        await _replayCurrent();
        return;
      }
      final nextIndex = _pickNextIndex();
      if (nextIndex == null) {
        if (_sleep.endOfQueue) {
          cancelSleepTimer();
          await _player.pause();
          await _player.seek(Duration.zero);
          notifyListeners();
          return;
        }
        // Check 2-hour inactivity guard
        if (DateTime.now().difference(_lastInteraction) > const Duration(hours: 2)) {
          debugPrint('[PlayerService] Autoplay paused due to 2-hour inactivity guard.');
          await _player.pause();
          await _player.seek(Duration.zero);
          notifyListeners();
          return;
        }

        // Autoplay: fetch next batch and continue when at the end of queue
        if (_autoplay && currentSong != null) {
          final token = _playRequestToken;
          final appended = await fetchAndAppendRecommendations();
          if (token != _playRequestToken || _isManuallyPaused) {
            DebugLog.write('[player] Autoplay aborted because playback was manually paused or cancelled during recommendation fetch');
            return;
          }
          if (appended && _queueIndex + 1 < _queue.length) {
            final target = _queue[_queueIndex + 1];
            _queueIndex = _queueIndex + 1;
            currentSong = target;
            if (_shuffle) {
              _shufflePlayedSongIds.add(target.id);
            }
            notifyListeners();
            await playSong(target, queue: _queue, userInitiated: userAction);
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

      await playSong(
        nextTrack,
        queue: _queue,
        initialIndex: nextIndex,
        userInitiated: userAction,
      );
    } catch (e) {
      DebugLog.write('[player] next error: $e');
    } finally {
      _isAdvancing = false;
      // Only a hand-off that reached playSong uses the long fade-in.
      _pendingFadeIn = null;
    }
  }

  Future<void> previous() async {
    if (_queue.isEmpty || _isAdvancing) return;
    _isAdvancing = true;
    final advanceToken = _playRequestToken;
    try {
      if (_player.playing && _userVolume > 0.05) {
        await _fadeVolume(0.0, duration: const Duration(milliseconds: 80));
        // Paused or superseded during the fade: stay put. The finally below
        // restores the volume.
        if (advanceToken != _playRequestToken) return;
      }
      _syncQueueIndexWithCurrentSong();
      final pos = _player.position;
      // A live stream has no start to go back to: Previous goes to the
      // previous song.
      if (pos > const Duration(seconds: 3) && !_isLive) {
        await seek(Duration.zero);
        return;
      }
      if (_loopMode == LoopSetting.one && _queueIndex <= 0) {
        await _replayCurrent();
        return;
      }
      if (_queueIndex > 0 && _queueIndex - 1 < _queue.length) {
        _queueIndex = _queueIndex - 1;
        final prevTrack = _queue[_queueIndex];
        currentSong = prevTrack;
        notifyListeners();
        await playSong(prevTrack, queue: _queue, initialIndex: _queueIndex);
      } else if (_loopMode == LoopSetting.all && _queue.length > 1) {
        _queueIndex = _queue.length - 1;
        final prevTrack = _queue[_queueIndex];
        currentSong = prevTrack;
        notifyListeners();
        await playSong(prevTrack, queue: _queue, initialIndex: _queueIndex);
      } else if (_queue.isNotEmpty) {
        await seek(Duration.zero);
      }
    } catch (e) {
      DebugLog.write('[player] previous error: $e');
    } finally {
      _isAdvancing = false;
      if (_player.playing && _player.volume < _effectiveVolume) {
        await _player.setVolume(_effectiveVolume);
      }
    }
  }


  Future<void> toggleLoop() {
    _loopMode = switch (_loopMode) {
      LoopSetting.off => LoopSetting.all,
      LoopSetting.all => LoopSetting.one,
      LoopSetting.one => LoopSetting.off,
    };
    _syncEngineLoop();
    _publishNotificationState();
    notifyListeners();
    return Future.value();
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    _shufflePlayedSongIds.clear();
    if (_shuffle && currentSong != null) {
      _shufflePlayedSongIds.add(currentSong!.id);
    }
    _publishNotificationState();
    notifyListeners();
  }

  /// Index of the next track, honouring shuffle + loop modes. Null means
  /// "stop" (loop off and at the end of the queue).
  int? _pickNextIndex() {
    if (_queue.isEmpty) return null;
    _syncQueueIndexWithCurrentSong();
    if (_shuffle) {
      final committed = _crossfadeShuffleIndex;
      _crossfadeShuffleIndex = null;
      if (committed != null && committed < _queue.length && committed != _queueIndex) {
        _shufflePlayedSongIds.add(_queue[committed].id);
        return committed;
      }
      if (_queue.length <= 1) {
        // Nothing else to shuffle to: behave like the end of the queue.
        if (_sleep.endOfQueue) return null;
        return _loopMode == LoopSetting.all ? 0 : null;
      }
      final immediateNext = _queueIndex + 1;
      if (immediateNext < _queue.length &&
          _lockedSongIds.contains(_queue[immediateNext].id)) {
        _shufflePlayedSongIds.add(_queue[immediateNext].id);
        return immediateNext;
      }
      final unplayed = [
        for (var i = 0; i < _queue.length; i++)
          if (!_shufflePlayedSongIds.contains(_queue[i].id) && i != _queueIndex) i,
      ];
      if (unplayed.isEmpty) {
        if (_sleep.endOfQueue) return null;
        if (_loopMode == LoopSetting.all) {
          _shufflePlayedSongIds.clear();
          if (currentSong != null) _shufflePlayedSongIds.add(currentSong!.id);
          final pool = [
            for (var i = 0; i < _queue.length; i++)
              if (i != _queueIndex) i,
          ];
          final r = pool.isNotEmpty
              ? pool[_random.nextInt(pool.length)]
              : _random.nextInt(_queue.length);
          _shufflePlayedSongIds.add(_queue[r].id);
          return r;
        }
        return null;
      }
      final picked = unplayed[_random.nextInt(unplayed.length)];
      _shufflePlayedSongIds.add(_queue[picked].id);
      return picked;
    }
    final next = _queueIndex + 1;
    if (next < _queue.length) return next;
    if (_sleep.endOfQueue) return null;
    if (_loopMode == LoopSetting.all) return 0;
    return null;
  }

  Future<void> _replayCurrent() async {
    _outroSkippedToken = -1;
    try {
      final song = currentSong;
      final start = song == null ? Duration.zero : _musicStartFor(song);
      final source = _player.audioSource;
      if (_player.processingState == ProcessingState.completed &&
          source != null) {
        // After a natural end just_audio still reports playing, so play()
        // alone is a no-op, and the media_kit backend only leaves the
        // completed state on a load or a buffering event (a seek within a
        // file on disk gives neither). The song would sit at its start
        // showing a play button, and the next tap reloads it from 0. Pause
        // so play() sends a real request, and reload the same source so the
        // state goes back to ready.
        await _player.pause();
        await _player.setAudioSource(source, initialPosition: start);
      } else {
        await _player.seek(start);
      }
      final targetVol = _effectiveVolume;
      await _player.setVolume(targetVol);
      await _player.play();
      await _player.setVolume(targetVol);
      _isManuallyPaused = false;
      _publishNotificationState();
      notifyListeners();
    } catch (e) {
      DebugLog.write('[player] _replayCurrent error: $e; reloading current song');
      if (currentSong != null) {
        await playSong(currentSong!);
      }
    }
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
    // A live stream's position is only what has been buffered; it is moved
    // with seekLive.
    if (_isLive) return;
    _silenceTail();
    // A seek back from the last seconds is the user's, not a loop wrap.
    _lastPosition = position;
    final dur = _player.duration;
    // A live stream's reported length is only what has been buffered, so
    // seeking to its end must not count as the song finishing.
    if (!_isLive &&
        dur != null &&
        dur > Duration.zero &&
        position >= dur - const Duration(milliseconds: 150)) {
      await _player.seek(dur);
      if (!_isAdvancing && !_isLoadingTrack) {
        if (!_player.playing || _isManuallyPaused) {
          // Paused at the end stays paused: seeking there is not a request to
          // start the next song.
          return;
        }
        if (_sleep.endOfSong) {
          cancelSleepTimer();
          unawaited(pause(smooth: true));
        } else {
          unawaited(next());
        }
      } else {
        _pendingNaturalAdvance = true;
      }
      return;
    }
    // A seek takes over from any fade in progress (such as a silent outro
    // fading out), so the song is heard at its level straight away.
    _volumeFadeToken++;
    await _player.seek(position);
    if (_player.volume < _effectiveVolume && _player.playing) {
      unawaited(_player.setVolume(_effectiveVolume));
    }
  }

  Future<void> setVolume(double value) async {
    final clamped = value.clamp(0.0, 1.0);
    if ((_userVolume - clamped).abs() < 0.001) return;
    _volumeFadeToken++;
    _userVolume = clamped;
    volumeNotifier.value = clamped;
    await _player.setVolume(_effectiveVolume);
    _saveVolumeDebounceTimer?.cancel();
    _saveVolumeDebounceTimer = Timer(const Duration(milliseconds: 400), () {
      identity?.setPlaybackVolume(_userVolume);
    });
  }

  /// Android 13+ (API 33+) requires the POST_NOTIFICATIONS runtime permission
  /// for app notifications to show. The media notification from
  /// audio_service is affected on many devices (vivo/Oppo/Xiaomi are
  /// strict). Request it once per process, on the first play. No-op on other
  /// platforms.
  static bool _notificationPermissionAsked = false;

  Future<void> _requestNotificationPermissionIfNeeded() async {
    if (!Platform.isAndroid) return;
    if (_notificationPermissionAsked) return;
    _notificationPermissionAsked = true;
    try {
      final status = await Permission.notification.status;
      if (!status.isGranted) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint('[player] notification permission request failed: $e');
    }
  }
}
