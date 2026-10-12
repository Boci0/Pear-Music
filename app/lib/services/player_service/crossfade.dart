part of '../player_service.dart';

mixin _PlayerCrossfade on ChangeNotifier {
  // What the crossfade needs from the player it is mixed into.
  AudioPlayer get _player;
  AudioPlayer Function() get _tailPlayerFactory;
  IdentityService? get identity;
  LibraryService get library;
  abstract Song? currentSong;
  abstract List<Song> _queue;
  abstract int _queueIndex;
  abstract bool _shuffle;
  abstract LoopSetting _loopMode;
  abstract bool _isManuallyPaused;
  abstract bool _isLoadingTrack;
  abstract bool _isAdvancing;
  abstract bool _isLive;
  abstract int _playRequestToken;
  abstract int _volumeFadeToken;
  abstract double _speed;
  abstract File? _currentLoadedFile;
  Set<String> get _lockedSongIds;
  Set<String> get _shufflePlayedSongIds;
  math.Random get _random;
  SleepTimer get _sleep;
  double get _effectiveVolume;
  LoopMode get _engineLoopMode;
  Future<void> _fadeVolume(
    double targetVolume, {
    Duration duration = const Duration(milliseconds: 150),
  });
  void _onNaturalEnd();
  Future<void> next({bool userAction = false, bool crossfade = false});

  // ---------------------------------------------------------------------
  // Crossfade
  //
  // The main player stays the single source of truth (queue, position,
  // notification, visualizer). A few seconds before a song ends, a second
  // "tail" player picks up the same file at the same position and fades it
  // out, while the main player moves on to the next song and fades it in.
  // Only natural song ends crossfade; skips, pauses and seeks stay instant
  // and silence any tail still fading.
  // ---------------------------------------------------------------------

  int _crossfadeSeconds = 0;
  int get crossfadeSeconds => _crossfadeSeconds;
  AudioPlayer? _tailPlayer;
  bool _crossfadeStarting = false;
  int _crossfadedToken = -1;
  int _tailToken = 0;
  Duration? _pendingFadeIn;

  /// The shuffle pick a crossfade committed to, used by the next advance.
  int? _crossfadeShuffleIndex;

  Future<void> setCrossfadeSeconds(int seconds) async {
    _crossfadeSeconds = seconds.clamp(0, IdentityService.maxCrossfadeSeconds);
    await identity?.setCrossfadeSeconds(_crossfadeSeconds);
    notifyListeners();
  }

  @visibleForTesting
  void debugCrossfadeTick(Duration position) => _onPosition(position);

  void _onPosition(Duration position) {
    _skipSilentIntroOnLoop(position);
    _lastPosition = position;
    _onPositionForCrossfade(position);
    _skipSilentOutro(position);
  }

  /// Last position seen by [_onPosition] (or asked for by [seek]), to tell
  /// the engine's repeat-one wrap from playback moving forward.
  Duration _lastPosition = Duration.zero;

  /// The engine's own repeat-one loop (see [_engineLoopMode]) wraps to 0,
  /// past the silent-intro skip a fresh start gets. When playback jumps from
  /// the last seconds of the song back to before its music starts, skip the
  /// intro again.
  void _skipSilentIntroOnLoop(Duration position) {
    final previous = _lastPosition;
    if (_engineLoopMode != LoopMode.one || _isLoadingTrack || _isAdvancing) {
      return;
    }
    final duration = _player.duration;
    if (duration == null ||
        previous < duration - const Duration(seconds: 3) ||
        position > const Duration(seconds: 2)) {
      return;
    }
    final song = currentSong;
    if (song == null) return;
    final start = _musicStartFor(song);
    if (start <= position) return;
    _outroSkippedToken = -1;
    _lastPosition = start;
    unawaited(_player.seek(start));
  }

  void _onPositionForCrossfade(Duration position) {
    if (_crossfadeSeconds <= 0 || _crossfadeStarting || _isLive) return;
    if (_crossfadedToken == _playRequestToken) return;
    if (!_player.playing || _isAdvancing || _isLoadingTrack || _isManuallyPaused) {
      return;
    }
    final duration = _player.duration;
    final fade = Duration(seconds: _crossfadeSeconds);
    // Very short clips just play out.
    if (duration == null || duration < fade * 3) return;
    final remaining = (_silentOutroStart() ?? duration) - position;
    if (remaining > fade || remaining < const Duration(milliseconds: 500)) {
      return;
    }
    if (_loopMode == LoopSetting.one || _sleep.endOfSong) return;
    final atEnd = _queueIndex >= _queue.length - 1;
    if (atEnd && (_sleep.endOfQueue || _loopMode != LoopSetting.all)) {
      // The queue ends here (or autoplay has to fetch more first): let the
      // song finish on its own.
      return;
    }
    int? shufflePick;
    if (_shuffle) {
      // Shuffle picks the next song now, among the ones that can start
      // straight away, so the fade never waits on a download.
      shufflePick = _readyShufflePick();
      if (shufflePick == null) return;
    } else if (!atEnd && !_isReadyToStart(_queue[_queueIndex + 1])) {
      // The next song would still have to download, which would leave a gap
      // in the middle of the fade. Play this one out instead.
      return;
    }
    _crossfadedToken = _playRequestToken;
    _crossfadeShuffleIndex = shufflePick;
    unawaited(_startCrossfade(remaining));
  }

  /// The index shuffle would move to next, limited to songs that are ready
  /// to start. Null when none is (the song then plays out on its own).
  int? _readyShufflePick() {
    final immediateNext = _queueIndex + 1;
    if (immediateNext < _queue.length &&
        _lockedSongIds.contains(_queue[immediateNext].id)) {
      return _isReadyToStart(_queue[immediateNext]) ? immediateNext : null;
    }
    final ready = [
      for (var i = 0; i < _queue.length; i++)
        if (i != _queueIndex &&
            !_shufflePlayedSongIds.contains(_queue[i].id) &&
            _isReadyToStart(_queue[i]))
          i,
    ];
    if (ready.isEmpty) return null;
    return ready[_random.nextInt(ready.length)];
  }

  // ---------------------------------------------------------------------
  // Silence skipping
  //
  // The loudness pass also records where each song's music starts and
  // stops. A silent intro is skipped when the song starts (keeping a short
  // lead-in and fading in), and a silent outro fades out and ends the song
  // early (crossfades end where the music does). Only two seconds or more
  // of silence is skipped; shorter gaps are part of the song.
  // ---------------------------------------------------------------------

  static const double _minSilenceSkip = 2.0;
  static const double _introLeadIn = 0.5;
  static const Duration _introFadeIn = Duration(milliseconds: 400);
  static const Duration _outroFadeOut = Duration(milliseconds: 1200);
  int _outroSkippedToken = -1;

  /// Where to start [song] so its silent intro is skipped.
  Duration _musicStartFor(Song song) {
    final span = LoudnessService.spanFor(song);
    if (span == null || span.musicStart < _minSilenceSkip) return Duration.zero;
    return Duration(milliseconds: ((span.musicStart - _introLeadIn) * 1000).round());
  }

  /// Where the current song's silent outro begins, or null when it has none
  /// worth skipping.
  Duration? _silentOutroStart() {
    final song = currentSong;
    final duration = _player.duration;
    if (song == null || duration == null) return null;
    final span = LoudnessService.spanFor(song);
    if (span == null) return null;
    // The span must describe this file: the decoder stops after 20 minutes.
    if ((span.length - duration.inMilliseconds / 1000).abs() > 1.5) return null;
    if (span.length - span.musicEnd < _minSilenceSkip) return null;
    return Duration(milliseconds: (span.musicEnd * 1000).round());
  }

  void _skipSilentOutro(Duration position) {
    if (_outroSkippedToken == _playRequestToken || _crossfadeStarting) return;
    if (_crossfadedToken == _playRequestToken) return;
    if (!_player.playing || _isAdvancing || _isLoadingTrack || _isManuallyPaused) {
      return;
    }
    final outro = _silentOutroStart();
    if (outro == null || position < outro) return;
    final token = _playRequestToken;
    _outroSkippedToken = token;
    DebugLog.write(
      '[player] "${currentSong?.title}" skips its silent outro at '
      '${outro.inMilliseconds}ms',
    );
    unawaited(() async {
      // Ease out over what is left of the tail rather than cutting it.
      await _fadeVolume(0.0, duration: _outroFadeOut);
      if (token != _playRequestToken) return;
      if (_isManuallyPaused || !_player.playing || _player.position < outro) {
        // Paused or seeked back during the fade: stay on this song.
        _outroSkippedToken = -1;
        if (_player.playing) unawaited(_fadeVolume(_effectiveVolume));
        return;
      }
      _onNaturalEnd();
    }());
  }

  static String _videoIdOf(Song song) =>
      RecommendationService.extractVideoId(song.id) ??
      song.id.replaceFirst('stream_', '');

  bool _isReadyToStart(Song song) {
    if (song.sourceDeviceId == 'stream') {
      return StreamCacheManager.isStreamCachedSync(_videoIdOf(song));
    }
    return library.hasSongFile(song);
  }

  Future<void> _startCrossfade(Duration remaining) async {
    _crossfadeStarting = true;
    final token = _playRequestToken;
    final song = currentSong;
    try {
      if (song == null) return;
      var file = _currentLoadedFile;
      if (file == null && song.sourceDeviceId == 'stream') {
        final videoId = RecommendationService.extractVideoId(song.id) ??
            song.id.replaceFirst('stream_', '');
        file = await StreamCacheManager.getCachedFile(videoId);
      }
      if (file == null || token != _playRequestToken || !_player.playing) {
        return;
      }
      final tail = _tailPlayer ??= _tailPlayerFactory();
      final tailToken = ++_tailToken;
      final handoverVolume = _player.volume;
      final handover = Stopwatch()..start();
      bool stale() =>
          token != _playRequestToken || tailToken != _tailToken || !_player.playing;
      // The tail starts muted and only takes over once it has been playing for
      // a moment in step with the main player. Muting the main player as soon
      // as the tail was told to play left a gap while its output started up,
      // then replayed that slice of the song.
      //
      // It starts [_tailLead] ahead so that, by the time its output is
      // running, it has lined up with the main player. Seeking it into line
      // afterwards is avoided: on Android a seek restarts the output, which
      // put the gap straight back. The lead is learned from each handover.
      final lead = _tailLead;
      await tail.setVolume(0.0);
      await tail.setSpeed(_speed);
      await tail.setAudioSource(
        AudioSource.file(file.path),
        initialPosition: _player.position + lead,
      );
      if (stale()) {
        unawaited(tail.stop());
        return;
      }
      unawaited(tail.play());
      var audible = await _waitUntilAudible(tail, stale);
      var drift = tail.position - _player.position;
      if (audible) {
        final learned = lead - drift;
        _tailLead = learned < Duration.zero
            ? Duration.zero
            : (learned > _maxTailLead ? _maxTailLead : learned);
      }
      if (audible && drift < -_handoverSeekThreshold) {
        // Far behind (a much slower start than learned): a seek, and its own
        // restart, is the lesser evil here.
        await tail.seek(_player.position + (lead - drift));
        audible = await _waitUntilAudible(tail, stale);
        drift = tail.position - _player.position;
      }
      if (stale()) {
        unawaited(tail.stop());
        return;
      }
      await _blendToTail(tail, handoverVolume);
      DebugLog.write(
        '[crossfade] "${song.title}" hands over with ${remaining.inMilliseconds}ms left '
        '(tail ${audible ? 'in step' : 'not confirmed'} after '
        '${handover.elapsedMilliseconds}ms, lead ${lead.inMilliseconds}ms, '
        'drift ${drift.inMilliseconds}ms, next lead ${_tailLead.inMilliseconds}ms)',
      );
      final fadeLeft = remaining - handover.elapsed;
      unawaited(_fadeOutTail(
        tail,
        tailToken,
        fadeLeft < const Duration(milliseconds: 300)
            ? const Duration(milliseconds: 300)
            : fadeLeft,
      ));
      _pendingFadeIn = Duration(seconds: _crossfadeSeconds);
      await next(crossfade: true);
    } catch (e) {
      DebugLog.write('[crossfade] failed, finishing the song normally: $e');
      _silenceTail();
      if (token == _playRequestToken && currentSong?.id == song?.id) {
        await _player.setVolume(_effectiveVolume);
      }
    } finally {
      _crossfadeStarting = false;
      _crossfadeShuffleIndex = null;
    }
  }

  /// How far ahead of the main player the tail is started, so it lines up
  /// once its output is running. Learned from each handover.
  Duration _tailLead = const Duration(milliseconds: 150);
  static const Duration _maxTailLead = Duration(milliseconds: 500);

  /// Behind by more than this at handover, the tail is seeked into line.
  static const Duration _handoverSeekThreshold = Duration(milliseconds: 120);

  /// Waits until [tail] has been playing for a moment. The reported position
  /// runs on from the moment playback is requested, before any sound comes
  /// out, so it takes 250 ms of it to be fairly sure the output is running.
  /// Gives up after a while so a slow device still hands over.
  Future<bool> _waitUntilAudible(AudioPlayer tail, bool Function() stale) async {
    final from = tail.position;
    final wait = Stopwatch()..start();
    while (wait.elapsed < const Duration(milliseconds: 1200)) {
      if (stale()) return false;
      if (tail.playing && tail.position - from >= const Duration(milliseconds: 250)) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return false;
  }

  /// Moves the sound from the main player to the tail over a few tens of
  /// milliseconds (equal power), so a small leftover offset between the two
  /// is not heard as a jump.
  Future<void> _blendToTail(AudioPlayer tail, double volume) async {
    const steps = 4;
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      await Future.wait([
        tail.setVolume(volume * math.sin(t * math.pi / 2)),
        _player.setVolume(i == steps ? 0.0 : volume * math.cos(t * math.pi / 2)),
      ]);
      if (i < steps) await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }

  /// Fades the tail out along an equal-power curve (so the overlap does not
  /// dip in the middle), then stops it.
  Future<void> _fadeOutTail(AudioPlayer tail, int tailToken, Duration over) async {
    final start = tail.volume;
    final steps = (over.inMilliseconds / 50).round().clamp(1, 400);
    final step = Duration(milliseconds: math.max(1, over.inMilliseconds ~/ steps));
    try {
      for (var i = 1; i <= steps; i++) {
        await Future<void>.delayed(step);
        if (tailToken != _tailToken) return;
        final t = i / steps;
        await tail.setVolume(start * PlayerService._mixerGain(math.cos(t * math.pi / 2)));
      }
    } finally {
      if (tailToken == _tailToken) unawaited(tail.stop());
    }
  }

  /// Fades the next song in along the matching sine curve while the tail
  /// fades out. Shares [_fadeVolume]'s token, so a pause or a volume change
  /// takes over from it.
  Future<void> _fadeInOverTail(double target, Duration over) async {
    final fadeToken = ++_volumeFadeToken;
    final steps = (over.inMilliseconds / 50).round().clamp(1, 400);
    final step = Duration(milliseconds: math.max(1, over.inMilliseconds ~/ steps));
    try {
      for (var i = 1; i <= steps; i++) {
        await Future<void>.delayed(step);
        if (fadeToken != _volumeFadeToken) return;
        final t = i / steps;
        await _player.setVolume(target * PlayerService._mixerGain(math.sin(t * math.pi / 2)));
      }
    } finally {
      if (fadeToken == _volumeFadeToken && _player.playing) {
        await _player.setVolume(target);
      }
    }
  }

  /// Stops a tail that is still fading (the user paused, skipped or seeked).
  void _silenceTail() {
    _tailToken++;
    _pendingFadeIn = null;
    final tail = _tailPlayer;
    if (tail != null) unawaited(tail.stop());
  }
}
