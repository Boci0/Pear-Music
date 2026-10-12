part of '../player_service.dart';

mixin _PlayerLive on ChangeNotifier {
  // What the live stream handling needs from the player it is mixed into.
  AudioPlayer get _player;
  abstract bool _isManuallyPaused;
  set _lastInteraction(DateTime value);
  int get _volumeFadeToken;
  set _volumeFadeToken(int value);

  /// Playing a live stream: no length, and it is rewound with [seekLive]
  /// rather than [seek].
  bool _isLive = false;
  bool get isLive => _isLive;

  @visibleForTesting
  void debugSetLive(bool value) {
    _isLive = value;
    notifyListeners();
  }

  @visibleForTesting
  void debugSetLiveBehind(double seconds) {
    _liveBehind = seconds;
    notifyListeners();
  }

  /// Seconds behind live when the live stream last (re)opened. It stays true
  /// while playing (the edge and playback both move at real time); a pause
  /// adds to it, which [liveBehind] accounts for.
  double _liveBehind = 0;
  DateTime? _livePausedSince;
  int _liveSeekToken = 0;

  /// How far behind the live edge playback is, in seconds. 0 when not live.
  double get liveBehind {
    if (!_isLive) return 0;
    final since = _livePausedSince;
    final paused = since == null
        ? 0.0
        : DateTime.now().difference(since).inMilliseconds / 1000;
    return _liveBehind + paused;
  }

  /// How much history the stream keeps, i.e. how far back it can be rewound.
  double get liveWindow => LiveHlsProxy.windowSeconds.value;

  /// True when playback has been rewound (or paused) past live.
  bool get isBehindLive => liveBehind > PlayerService.liveCloseEnough;

  /// Moves a live stream to [behind] seconds behind the edge; 0 or anything
  /// within [PlayerService.liveCloseEnough] returns to live. Reopens the relay's stream,
  /// which takes a moment (a rebuffer), so a drag should call it once at the
  /// end.
  Future<void> seekLive(double behind) async {
    if (!_isLive) return;
    _lastInteraction = DateTime.now();
    final window = liveWindow;
    final target = behind.clamp(0.0, window > 0 ? window : behind).toDouble();
    await _openLive(target <= PlayerService.liveCloseEnough ? 0 : target);
  }

  /// Back to the live edge.
  Future<void> goLive() => seekLive(0);

  Future<void> _openLive(double behind) async {
    final uri = LiveHlsProxy.address(
      behind: behind <= 0 ? null : LiveHlsProxy.defaultLead + behind,
    );
    if (uri == null) return;
    final token = ++_liveSeekToken;
    final paused = _isManuallyPaused || !_player.playing;
    _liveBehind = behind;
    _livePausedSince = paused ? DateTime.now() : null;
    notifyListeners();
    // A seek takes over from any fade in progress, as [seek] does.
    _volumeFadeToken++;
    try {
      await _player
          .setAudioSource(AudioSource.uri(uri))
          .timeout(PlayerService._earlyStreamOpenTimeout);
    } catch (e) {
      DebugLog.write('[player] Live stream would not reopen $behind s back: $e');
      return;
    }
    if (token != _liveSeekToken || !_isLive) return;
    DebugLog.write(
      '[player] LIVE ${behind <= 0 ? 'at the edge' : '${behind.round()} s behind'}',
    );
    if (!paused) await _player.play();
    notifyListeners();
  }
}
