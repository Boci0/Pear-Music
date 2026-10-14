import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/song.dart';
import 'debug_log.dart';
import 'identity_service.dart';
import 'innertube_audio_engine.dart';
import 'library_service.dart';
import 'player_service.dart';
import 'stream_cache_manager.dart';
import 'video_relay.dart';

/// The video library could not be started on this device.
class VideoUnavailable implements Exception {
  const VideoUnavailable(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

typedef _Link = ({
  String url,
  Map<String, String> headers,
  int height,
  DateTime at,
});

/// Shows the picture of a song that has one, next to the audio the
/// [PlayerService] already plays.
///
/// The audio player stays the master. This holds a second, muted `media_kit`
/// player that only renders video and follows the audio player's play state
/// and position; it exists only while the video is shown. A local video file
/// plays from disk; a streamed song gets a picture-only link through the
/// counting [VideoRelay], capped by the quality setting.
class VideoService extends ChangeNotifier with WidgetsBindingObserver {
  VideoService(this._player, this._library, [this._identity]);

  final PlayerService _player;
  final LibraryService _library;
  final IdentityService? _identity;

  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isAndroid);

  /// Video files can be imported from the file picker (Windows only).
  static bool get canImportVideoFiles => !kIsWeb && Platform.isWindows;

  static const MethodChannel _network =
      MethodChannel('com.peerm.peerm_app/network');

  /// The tallest picture to ask for: [setting] is the saved choice (0 = let
  /// the app decide); mobile data gets 360p, everything else 720p.
  @visibleForTesting
  static int pickHeight({required int setting, required bool metered}) {
    if (setting == 360 || setting == 480 || setting == 720) return setting;
    return metered ? 360 : 720;
  }

  Future<bool> _isMetered() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      return await _network.invokeMethod<bool>('isMetered') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<int> _maxHeight() async => pickHeight(
        setting: _identity?.videoQuality ?? 0,
        metered: await _isMetered(),
      );

  /// Containers that can carry a picture. A first filter only: cached stream
  /// audio is `.mp4`/`.webm` too, so [_load] checks for a video track.
  static const Set<String> videoExtensions = {
    'mp4', 'mkv', 'webm', 'mov', 'm4v', 'avi',
  };

  /// How far the picture may drift from the sound before it is pulled back.
  static const Duration maxDrift = Duration(milliseconds: 350);

  static const Duration _followEvery = Duration(milliseconds: 300);

  /// A streamed picture further than this from the sound is reopened at the
  /// right place: mpv's own seek in a network stream reads tens of MB.
  static const Duration reopenDrift = Duration(seconds: 4);

  /// The YouTube video id of a streamed song, or null for anything else.
  static String? streamVideoId(Song song) =>
      !song.isLive && song.id.startsWith('stream_') && song.id.length > 7
          ? song.id.substring(7)
          : null;

  static bool mayHaveVideo(Song song) =>
      !song.isLive &&
      (streamVideoId(song) != null ||
          (song.sourceDeviceId != 'stream' &&
              videoExtensions.contains(song.extension)));

  @visibleForTesting
  static bool needsSeek(Duration video, Duration audio) =>
      (video - audio).abs() > maxDrift;

  /// How long a seek is given to land; asking again every tick would restart
  /// a streamed seek each time.
  static const Duration seekGrace = Duration(seconds: 4);

  /// Whether to issue a (new) seek now. [lastTarget] and [sinceLast] describe
  /// the previous seek; audio jumping away from where it expects always seeks.
  @visibleForTesting
  static bool shouldSeek({
    required Duration video,
    required Duration audio,
    Duration? lastTarget,
    Duration? sinceLast,
    double speed = 1.0,
  }) {
    if (!needsSeek(video, audio)) return false;
    if (lastTarget == null || sinceLast == null || sinceLast > seekGrace) {
      return true;
    }
    final expected = lastTarget + sinceLast * speed;
    return (audio - expected).abs() > const Duration(milliseconds: 1500);
  }

  /// Picture links found a moment ago, so toggling the picture does not ask
  /// YouTube again. Tied to this connection and short lived.
  final Map<String, _Link> _links = {};
  static const Duration _linkLife = Duration(minutes: 15);

  static bool _libraryStarted = false;

  bool _shown = false;
  Player? _video;
  VideoController? _controller;
  String? _loadedId;
  bool _ready = false;
  int _token = 0;
  Timer? _follow;
  Duration? _lastSeekTarget;
  final Stopwatch _sinceSeek = Stopwatch();
  Media? _streamMedia;
  Rect _crop = const Rect.fromLTRB(0, 0, 1, 1);
  int? _streamHeight;

  /// Height in lines of the streamed picture; null for a file on disk.
  int? get streamHeight => _streamHeight;

  /// The part of the frame worth showing, as fractions of it (see [scanBars]).
  Rect get crop => _crop;

  /// Width over height of the whole frame; null until it is known.
  double? get frameAspect {
    final w = _video?.state.width ?? 0;
    final h = _video?.state.height ?? 0;
    return w > 0 && h > 0 ? w / h : null;
  }

  /// A column or row counts as black while its brightest pixel is under this.
  static const int _blackLevel = 14;

  /// A bar must be at least this share of the frame to be worth cutting.
  static const double _minBar = 0.04;

  /// Looks for black bars in a frame's RGBA bytes. `conclusive` is false for
  /// a frame too dark to tell (a fade-in); `crop` is null when there is
  /// nothing to trim.
  @visibleForTesting
  static ({bool conclusive, Rect? crop}) scanBars(
    Uint8List rgba,
    int width,
    int height,
  ) {
    if (width < 16 || height < 16) return (conclusive: false, crop: null);
    final colMax = List<int>.filled(width, 0);
    final rowMax = List<int>.filled(height, 0);
    for (var y = 0; y < height; y += 3) {
      final base = y * width * 4;
      var rowBrightest = 0;
      for (var x = 0; x < width; x++) {
        final i = base + x * 4;
        final v = math.max(rgba[i], math.max(rgba[i + 1], rgba[i + 2]));
        if (v > colMax[x]) colMax[x] = v;
        if (v > rowBrightest) rowBrightest = v;
      }
      rowMax[y] = rowBrightest;
    }
    int firstLit(List<int> a, {int step = 1}) {
      for (var i = 0; i < a.length; i += step) {
        if (a[i] >= _blackLevel) return i;
      }
      return -1;
    }

    int lastLit(List<int> a, {int step = 1}) {
      for (var i = a.length - 1; i >= 0; i -= 1) {
        if (step > 1 && i % step != 0) continue;
        if (a[i] >= _blackLevel) return i;
      }
      return -1;
    }

    final left = firstLit(colMax);
    final right = lastLit(colMax);
    final top = firstLit(rowMax, step: 3);
    final bottom = lastLit(rowMax, step: 3);
    if (left < 0 || top < 0) return (conclusive: false, crop: null);

    // Keep a hair inside the picture so compression fringe is cut too.
    final l = left == 0 ? 0.0 : (left + 2) / width;
    final r = right >= width - 1 ? 1.0 : (right - 1) / width;
    final t = top == 0 ? 0.0 : (top + 2) / height;
    final b = bottom >= height - 3 ? 1.0 : (bottom + 1) / height;
    final w = r - l;
    final h = b - t;
    if (w < 0.2 || h < 0.2) return (conclusive: true, crop: null);
    if (1 - w < _minBar && 1 - h < _minBar) {
      return (conclusive: true, crop: null);
    }
    return (conclusive: true, crop: Rect.fromLTRB(l, t, r, b));
  }

  /// Songs with no video track at all.
  final Set<String> _noPicture = {};

  /// Songs whose picture failed this time, and why; worth another try.
  /// Cleared by [show] and [retry].
  final Map<String, String> _failed = {};

  /// Why the picture of the song on show could not start; null if nothing is.
  String? get failure {
    final song = _player.currentSong;
    return song == null ? null : _failed[song.id];
  }

  /// Tries the song on show again, after a failure.
  void retry() {
    final song = _player.currentSong;
    if (song == null) return;
    _failed.remove(song.id);
    _loadedId = null;
    notifyListeners();
    unawaited(_sync());
  }

  /// Where the picture is drawn; null until a file with video is loaded.
  VideoController? get controller => _ready ? _controller : null;

  /// Whether to offer the video button for [song].
  bool canOffer(Song? song) =>
      supported &&
      song != null &&
      mayHaveVideo(song) &&
      !_noPicture.contains(song.id);

  /// Whether the picture, not the artwork, is what [song] shows right now.
  bool showingFor(Song? song) => _shown && canOffer(song);

  void toggle() => _shown ? hide() : show();

  /// Nothing is fetched unseen: the picture stops when the app leaves the
  /// screen. The sound goes on.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      hide();
    }
  }

  /// What a check driving the app can read (control port).
  Map<String, Object?> get status => {
    'shown': _shown,
    'ready': _ready,
    'videoPositionMs': _video?.state.position.inMilliseconds,
    'videoPlaying': _video?.state.playing,
    'networkBytes': VideoRelay.bytesUsed.value,
    'crop': [_crop.left, _crop.top, _crop.right, _crop.bottom],
  };

  void show() {
    if (_shown || !supported) return;
    _shown = true;
    _failed.clear();
    WidgetsBinding.instance.addObserver(this);
    _player.addListener(_sync);
    _follow = Timer.periodic(_followEvery, (_) => _followAudio());
    notifyListeners();
    unawaited(_sync());
  }

  void hide() {
    if (!_shown) return;
    _shown = false;
    WidgetsBinding.instance.removeObserver(this);
    _player.removeListener(_sync);
    _follow?.cancel();
    _follow = null;
    _teardown();
    notifyListeners();
  }

  Future<void> _sync() async {
    if (!_shown) return;
    final song = _player.currentSong;
    if (song == null || !canOffer(song)) {
      // No picture for this song: show its artwork, keep the switch on.
      if (_loadedId != null) {
        _teardown();
        notifyListeners();
      }
      return;
    }
    if (_loadedId != song.id && !_failed.containsKey(song.id)) {
      await _load(song);
    }
  }

  Future<void> _load(Song song) async {
    final token = ++_token;
    _loadedId = song.id;
    _ready = false;
    _resetPicture(); // nothing of the previous song carries over
    // Gives up on [song]: records why (if given) and drops the picture.
    void giveUp(String? failure) {
      if (failure != null) _failed[song.id] = failure;
      _teardown();
      notifyListeners();
    }

    try {
      final Media media;
      final streamId = streamVideoId(song);
      if (streamId != null) {
        final maxHeight = await _maxHeight();
        final key = '$streamId@$maxHeight';
        Future<({String url, Map<String, String> headers})?> ytDlp() async {
          final l = await StreamCacheManager.resolveVideoLink(
            streamId,
            maxHeight: maxHeight,
          );
          return l == null ? null : (url: l.url, headers: l.headers);
        }

        var link = _links[key];
        if (link == null || DateTime.now().difference(link.at) >= _linkLife) {
          // The fast engine's one lookup first; yt-dlp when it is resting
          // after a block or has nothing for this video.
          try {
            final fast = await InnerTubeAudioEngine.videoLink(
              streamId,
              maxHeight: maxHeight,
            );
            link = (
              url: fast.url,
              headers: InnerTubeAudioEngine.videoHeaders,
              height: fast.height,
              at: DateTime.now(),
            );
            _links[key] = link;
          } on InnerTubeFailure catch (e) {
            DebugLog.write(
              '[video] fast lookup said "${e.message}", using yt-dlp',
            );
            final l = await ytDlp();
            if (l == null) throw InnerTubeFailure('no picture link');
            link = (
              url: l.url,
              headers: l.headers,
              height: maxHeight,
              at: DateTime.now(),
            );
          }
        }
        _streamHeight = link.height;
        if (token != _token || !_shown) return;
        // Through the relay, so the traffic is counted and read in ranges; a
        // refused link is looked up again through yt-dlp, once.
        final local = await VideoRelay.serve(
          link.url,
          headers: link.headers,
          relink: ytDlp,
        );
        media = _streamMedia = Media(local.toString());
      } else {
        final file = _library.songFile(song);
        if (!await file.exists()) {
          if (token == _token) {
            giveUp('This file is not in the library any more.');
          }
          return;
        }
        media = Media(file.path);
      }
      final video = _video ?? await _createPlayer();
      if (token != _token || !_shown) {
        // Hidden, or another song asked for, while the player was starting.
        if (!identical(video, _video)) {
          _controller = null;
          unawaited(video.dispose());
        }
        return;
      }
      _video = video;
      await video.open(media, play: false);
      var hasPicture = (video.state.width ?? 0) > 0;
      if (!hasPicture) {
        try {
          await video.stream.width
              .firstWhere((w) => (w ?? 0) > 0)
              // A streamed picture may first have to find a new link.
              .timeout(Duration(seconds: streamId != null ? 15 : 5));
          hasPicture = true;
        } on TimeoutException {
          hasPicture = false;
        }
      }
      if (token != _token || !_shown) return;
      if (!hasPicture) {
        if (streamId != null) {
          // A stream always has a picture: it did not arrive.
          DebugLog.write('[video] the picture of ${song.title} did not start');
          giveUp('The video did not start. YouTube may be refusing right now.');
        } else {
          DebugLog.write('[video] ${song.title} has no video track');
          _noPicture.add(song.id);
          giveUp(null);
        }
        return;
      }
      _ready = true;
      await video.setRate(_player.speed);
      await video.seek(_player.position ?? Duration.zero);
      if (_player.playing) await video.play();
      notifyListeners();
      unawaited(_trimBars(token, video));
    } on VideoUnavailable catch (e) {
      DebugLog.write('[video] video is unavailable here: ${e.reason}');
      if (token == _token) giveUp('Video is not available on this device.');
    } catch (e) {
      DebugLog.write('[video] could not open the video for ${song.title}: $e');
      if (token == _token) {
        giveUp('Could not get the video. YouTube may be refusing right now.');
      }
    }
  }

  /// Whether two bar scans found the same area. Bars are only cut once two
  /// frames agree, so one dark fade-in frame cannot crop real content away.
  @visibleForTesting
  static bool cropsAgree(Rect a, Rect b) =>
      (a.left - b.left).abs() < 0.02 &&
      (a.top - b.top).abs() < 0.02 &&
      (a.right - b.right).abs() < 0.02 &&
      (a.bottom - b.bottom).abs() < 0.02;

  Future<void> _trimBars(int token, Player video) async {
    Rect? previous;
    for (final wait in const [
      Duration(milliseconds: 1500),
      Duration(seconds: 3),
      Duration(seconds: 5),
      Duration(seconds: 8),
    ]) {
      await Future<void>.delayed(wait);
      if (token != _token || !_shown) return;
      try {
        final png = await video.screenshot(format: 'image/png');
        if (png == null) continue;
        final codec = await ui.instantiateImageCodec(png);
        final frame = await codec.getNextFrame();
        final image = frame.image;
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final scan = data == null
            ? (conclusive: false, crop: null as Rect?)
            : scanBars(data.buffer.asUint8List(), image.width, image.height);
        image.dispose();
        codec.dispose();
        if (token != _token) return;
        final found = scan.crop;
        if (found != null) {
          if (previous != null && cropsAgree(previous, found)) {
            _crop = found;
            DebugLog.write('[video] trimmed black bars: $_crop');
            notifyListeners();
            return;
          }
          previous = found;
        } else if (scan.conclusive) {
          // A lit frame with no bars: nothing to cut.
          return;
        }
      } catch (e) {
        DebugLog.write('[video] could not look for black bars: $e');
        return;
      }
    }
  }

  Future<Player> _createPlayer() async {
    if (!kIsWeb && Platform.isAndroid && !_libraryStarted) {
      // The library's start-up loops forever when the plugin's Java side never
      // hands it the VM (a stale generated registrant did this and froze the
      // app). Start it on a helper first: when that finishes the real call
      // below is instant, when it does not video is unavailable.
      try {
        await Isolate.run(() {
          MediaKit.ensureInitialized();
          return true;
        }).timeout(const Duration(seconds: 10));
      } on TimeoutException {
        throw const VideoUnavailable('the video library did not load in time');
      } catch (e) {
        throw VideoUnavailable('the video library could not be loaded: $e');
      }
      _libraryStarted = true;
    }
    MediaKit.ensureInitialized();
    final player = Player(
      configuration: const PlayerConfiguration(
        title: 'Pear Music video',
        logLevel: MPVLogLevel.error,
        // Every byte read ahead is wasted if the song is skipped, and every
        // jump refills it: keep it small.
        bufferSize: 4 * 1024 * 1024,
      ),
    );
    final platform = player.platform;
    if (platform is NativePlayer) {
      // The audio player owns the sound: no audio decoding here.
      await platform.setProperty('aid', 'no');
      // Keep the cache in memory (media_kit spools to disk by default) and
      // bound it by time as well as bytes.
      await platform.setProperty('cache-on-disk', 'no');
      await platform.setProperty('cache-secs', '8');
      await platform.setProperty('demuxer-readahead-secs', '8');
      // The relay answers in windows: ask for the next one at a window's end.
      await platform.setProperty(
        'stream-lavf-o',
        'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2',
      );
    }
    _controller = VideoController(player);
    return player;
  }

  void _followAudio() {
    final video = _video;
    if (!_ready || video == null) return;
    final playing = _player.playing;
    if (playing != video.state.playing) {
      unawaited(playing ? video.play() : video.pause());
    }
    final audioPos = _player.position ?? Duration.zero;
    if (shouldSeek(
      video: video.state.position,
      audio: audioPos,
      lastTarget: _lastSeekTarget,
      sinceLast: _lastSeekTarget == null ? null : _sinceSeek.elapsed,
      speed: _player.speed,
    )) {
      _lastSeekTarget = audioPos;
      _sinceSeek
        ..reset()
        ..start();
      final stream = _streamMedia;
      if (stream != null &&
          (video.state.position - audioPos).abs() > reopenDrift) {
        unawaited(
          video.open(
            Media(
              stream.uri,
              httpHeaders: stream.httpHeaders,
              start: audioPos,
            ),
            play: playing,
          ),
        );
      } else {
        unawaited(video.seek(audioPos));
      }
    }
    if ((video.state.rate - _player.speed).abs() > 0.01) {
      unawaited(video.setRate(_player.speed));
    }
  }

  /// Clears everything that belongs to the picture of one song.
  void _resetPicture() {
    _lastSeekTarget = null;
    _sinceSeek.stop();
    _streamMedia = null;
    _crop = const Rect.fromLTRB(0, 0, 1, 1);
    _streamHeight = null;
    VideoRelay.stop();
  }

  void _teardown() {
    _token++;
    _ready = false;
    _loadedId = null;
    _resetPicture();
    final video = _video;
    _video = null;
    _controller = null;
    if (video != null) unawaited(video.dispose());
  }

  @override
  void dispose() {
    _player.removeListener(_sync);
    _follow?.cancel();
    _teardown();
    super.dispose();
  }
}
