import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:system_audio_visualizer/system_audio_visualizer.dart';

import 'player_service.dart';
import 'window_focus.dart';

/// The one source of spectrum data for every visualizer in the app.
///
/// The native capture (WASAPI loopback on Windows, the Visualizer effect on
/// Android) is a single resource: two widgets starting and stopping it on their
/// own would cut each other off. So widgets [acquire] the feed while they are
/// on screen and [release] it when they go; the capture runs while at least one
/// holds it, the song is playing and the app is in the foreground with its
/// window active, and stops otherwise.
///
/// The feed turns the raw FFT into [barCount] band targets, 0..1, bass in
/// index 0 and treble in the last. Each widget smooths those with its own
/// [SpectrumPhysics] and draws them.
class VisualizerFeed with WidgetsBindingObserver {
  VisualizerFeed._();

  static final VisualizerFeed instance = VisualizerFeed._();

  static const int barCount = 24;

  static const _androidChannel = MethodChannel('com.peerm.peerm_app/visualizer');
  static const _androidStream =
      EventChannel('com.peerm.peerm_app/visualizer_stream');

  /// Band targets the widgets move their bars towards.
  final List<double> targetBins = List<double>.filled(barCount, 0.0);

  /// Bumped when playback or the render state changes, so widgets can park or
  /// start their tickers.
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  PlayerService? _player;
  int _clients = 0;

  bool _isAppForeground = true;
  bool _windowFocused = true;

  StreamSubscription<List<double>>? _fftSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription? _androidSub;
  StreamSubscription<int?>? _sessionIdSub;
  bool _hasNativeFft = false;
  bool _wasapiRunning = false;
  bool _androidRunning = false;
  int? _currentBoundSessionId;

  int _basePositionMs = 0;
  int _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
  int _lastRefreshMs = 0;

  /// True while the microphone explanation or prompt is on screen: the bars
  /// stay still instead of dancing to a made-up pattern behind it.
  bool awaitingPermission = false;

  // Slow per-band loudness average used by the auto-gain ("leveling") stage so
  // quiet bands still contribute movement.
  final List<double> _bandAvg = List<double>.filled(barCount, 0.0);

  // Precomputed FFT band edges and high-frequency compensation, rebuilt only
  // when the incoming bin count changes.
  int _mappedRawLen = -1;
  final List<int> _bandStart = List<int>.filled(barCount, 0);
  final List<int> _bandEnd = List<int>.filled(barCount, 1);
  final List<double> _bandHfComp = List<double>.filled(barCount, 1.0);

  bool get hasNativeFft => _hasNativeFft;

  bool get playing => _player?.playing ?? false;

  /// True when the app is in the foreground and its window is the active one.
  bool get renderActive => _isAppForeground && _windowFocused;

  int get clientCount => _clients;

  /// Call when a visualizer widget mounts.
  void acquire(PlayerService player) {
    if (_clients > 0 && !identical(_player, player)) {
      _unbind();
      _clients = 0;
    }
    if (_clients == 0) {
      _player = player;
      _bind(player);
    }
    _clients++;
    _syncCapture();
  }

  /// Call when a visualizer widget goes away.
  void release() {
    if (_clients == 0) return;
    _clients--;
    if (_clients == 0) _unbind();
  }

  void _bind(PlayerService player) {
    _isAppForeground = true;
    _windowFocused = WindowFocus.focused.value;
    _basePositionMs = player.position?.inMilliseconds ?? 0;
    _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
    _positionSub = player.positionStream.listen((pos) {
      _basePositionMs = pos.inMilliseconds;
      _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
    });
    WidgetsBinding.instance.addObserver(this);
    player.addListener(_onPlayerChanged);
    WindowFocus.focused.addListener(_onWindowFocusChanged);
  }

  void _unbind() {
    _stopCapture();
    _positionSub?.cancel();
    _positionSub = null;
    WidgetsBinding.instance.removeObserver(this);
    _player?.removeListener(_onPlayerChanged);
    WindowFocus.focused.removeListener(_onWindowFocusChanged);
    _player = null;
    for (var i = 0; i < barCount; i++) {
      targetBins[i] = 0.0;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_isAppForeground == foreground) return;
    _isAppForeground = foreground;
    _syncCapture();
    changes.value++;
  }

  void _onWindowFocusChanged() {
    final focused = WindowFocus.focused.value;
    if (_windowFocused == focused) return;
    _windowFocused = focused;
    _syncCapture();
    changes.value++;
  }

  void _onPlayerChanged() {
    if (playing) {
      _basePositionMs = _player?.position?.inMilliseconds ?? 0;
      _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
    }
    _syncCapture();
    changes.value++;
  }

  /// Starts or stops the native capture to match [playing] and [renderActive].
  void _syncCapture() {
    if (_clients > 0 && playing && renderActive) {
      _startCapture();
    } else {
      _stopCapture();
    }
  }

  /// Restarts the capture, for after the audio permission was just granted.
  void restartCapture() {
    _stopCapture();
    _syncCapture();
  }

  void _startCapture() {
    if (kIsWeb) return;
    if (Platform.isWindows) {
      _startWasapiCapture();
    } else if (Platform.isAndroid) {
      _startAndroidCapture();
    }
  }

  void _stopCapture() {
    _stopWasapiCapture();
    _stopAndroidCapture();
    for (var i = 0; i < barCount; i++) {
      _bandAvg[i] = 0.0;
    }
  }

  Future<void> _startAndroidCapture() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      // Asked for with an explanation (see VisualizerPermission), never here:
      // the visualizer starts by itself when the player opens, and a bare
      // system prompt at that moment would come out of nowhere.
      final status = await Permission.microphone.status;
      if (!status.isGranted) {
        _hasNativeFft = false;
        return;
      }
      final player = _player;
      if (_clients == 0 || player == null || !player.playing) return;

      _androidSub ??= _androidStream.receiveBroadcastStream().listen(
        (raw) {
          if (raw is List && raw.isNotEmpty) {
            _hasNativeFft = true;
            _processFft(raw.map((e) => (e as num).toDouble()).toList());
          }
        },
        onError: (_) {
          _hasNativeFft = false;
        },
      );

      _sessionIdSub?.cancel();
      _sessionIdSub = player.androidAudioSessionIdStream.listen((newId) {
        if (_clients == 0 || !playing) return;
        final target = (newId != null && newId > 0) ? newId : 0;
        if (target != _currentBoundSessionId) {
          _bindAndroidSession(target);
        }
      });

      final currentId = player.androidAudioSessionId;
      final initialTarget = (currentId != null && currentId > 0) ? currentId : 0;
      await _bindAndroidSession(initialTarget);
    } catch (_) {
      _hasNativeFft = false;
    }
  }

  Future<void> _bindAndroidSession(int sessionId) async {
    if (_currentBoundSessionId == sessionId && _androidRunning) return;
    try {
      final success = await _androidChannel
              .invokeMethod<bool>('start', {'sessionId': sessionId}) ??
          false;
      if (success) {
        _androidRunning = true;
        _currentBoundSessionId = sessionId;
      }
    } catch (_) {
      _hasNativeFft = false;
    }
  }

  void _stopAndroidCapture() {
    if (kIsWeb || !Platform.isAndroid) return;
    _androidRunning = false;
    _currentBoundSessionId = null;
    _hasNativeFft = false;
    _sessionIdSub?.cancel();
    _sessionIdSub = null;
    _androidSub?.cancel();
    _androidSub = null;
    try {
      _androidChannel.invokeMethod('stop').catchError((_) {});
    } catch (_) {}
  }

  void _startWasapiCapture() {
    if (kIsWeb || !Platform.isWindows || _wasapiRunning) return;
    _wasapiRunning = true;
    try {
      SystemAudioVisualizer.start(fftSize: 2048, bins: 64).catchError((_) {});
      _fftSub?.cancel();
      _fftSub = SystemAudioVisualizer.fftStream.listen(
        (raw) {
          if (raw.isNotEmpty) {
            _hasNativeFft = true;
            _processFft(raw);
          }
        },
        onError: (_) {
          _hasNativeFft = false;
        },
      );
    } catch (_) {
      _hasNativeFft = false;
    }
  }

  void _stopWasapiCapture() {
    if (kIsWeb || !Platform.isWindows || !_wasapiRunning) return;
    _wasapiRunning = false;
    _fftSub?.cancel();
    _fftSub = null;
    try {
      SystemAudioVisualizer.stop().catchError((_) {});
    } catch (_) {}
  }

  /// Precomputes the FFT band edges and the high-frequency compensation for
  /// the current bin count; only does work when the bin count changed.
  void _rebuildBandMap(int rawLen) {
    if (_mappedRawLen == rawLen) return;
    _mappedRawLen = rawLen;
    final int minMusicalBin = math.min(3, math.max(0, rawLen - 12)).toInt();
    final int maxMusicalBin = math.min(56, math.max(8, rawLen - 1)).toInt();
    final int span =
        math.max(1, math.min(rawLen - 1, maxMusicalBin) - minMusicalBin).toInt();
    const double warp = 1.15;
    const double tilt = 1.40;
    for (int i = 0; i < barCount; i++) {
      final fracLow = math.pow(i / barCount, warp).toDouble();
      final fracHigh = math.pow((i + 1) / barCount, warp).toDouble();
      final startIdx =
          (minMusicalBin + fracLow * span).floor().clamp(0, rawLen - 1);
      _bandStart[i] = startIdx;
      _bandEnd[i] = math.max(
        startIdx + 1,
        (minMusicalBin + fracHigh * (span + 1)).ceil().clamp(0, rawLen),
      );
      _bandHfComp[i] = 1.0 + tilt * math.pow(i / (barCount - 1), 0.85).toDouble();
    }
  }

  /// Maps a raw FFT frame to the band targets. Public for tests.
  @visibleForTesting
  void processFft(List<double> raw) => _processFft(raw);

  void _processFft(List<double> raw) {
    final rawLen = raw.length;
    if (rawLen == 0) return;

    _rebuildBandMap(rawLen);

    // Global silence detection: WASAPI loopback still returns minute
    // quantization noise when nothing plays, so if the total energy is below
    // audible level every target is shut off at once.
    double maxRaw = 0.0;
    double sumRaw = 0.0;
    for (int k = 0; k < rawLen; k++) {
      final v = raw[k];
      sumRaw += v;
      if (v > maxRaw) maxRaw = v;
    }
    final meanRaw = sumRaw / rawLen;

    if (maxRaw < 0.08 || meanRaw < 0.020) {
      for (int i = 0; i < barCount; i++) {
        targetBins[i] = 0.0;
        _bandAvg[i] *= 0.97;
      }
      return;
    }

    // Band 0 = bass, band 23 = treble. Octave-warped so low and mid
    // frequencies do not dominate the lower bands, with progressive
    // high-frequency compensation for natural acoustic balance.
    const double binNoiseGate = 0.020;
    const double gain = 1.15;

    for (int i = 0; i < barCount; i++) {
      final startIdx = _bandStart[i];
      final endIdx = _bandEnd[i];

      double sum = 0.0;
      int count = 0;
      for (int j = startIdx; j < endIdx; j++) {
        sum += raw[j];
        count++;
      }
      final rawAmp = count > 0 ? (sum / count) : raw[startIdx];

      if (rawAmp < binNoiseGate) {
        targetBins[i] = 0.0;
        _bandAvg[i] *= 0.997;
        continue;
      }
      final gated = (rawAmp - binNoiseGate) / math.max(0.001, (1.0 - binNoiseGate));

      final scaled = (gated * gain * _bandHfComp[i]).clamp(0.0, 1.0);

      // Per-band auto-gain blends the absolute amplitude with the band's level
      // relative to its own slow average so quiet bands still contribute.
      const double leveling = 0.50;
      final leveled = (scaled / (_bandAvg[i] * 1.6 + 0.004)).clamp(0.0, 1.0);
      final mixed = scaled * (1.0 - leveling) + leveled * leveling;
      _bandAvg[i] = _bandAvg[i] * 0.992 + scaled * 0.008;

      // Temporal damping keeps the derived targets stable and musical.
      final prev = targetBins[i];
      targetBins[i] = mixed > prev
          ? prev + (mixed - prev) * 0.85
          : prev + (mixed - prev) * 0.58;
    }
  }

  /// Called by a widget on every tick. Fills the targets with the harmonic
  /// stand-in when there is no native spectrum, at most once per millisecond
  /// however many widgets are ticking.
  void refresh() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now == _lastRefreshMs) return;
    _lastRefreshMs = now;
    if (awaitingPermission) {
      for (var i = 0; i < barCount; i++) {
        targetBins[i] = 0.0;
      }
      return;
    }
    if (!_hasNativeFft && playing) _generateHarmonicFallback();
  }

  double get _smoothSongMs {
    if (!playing) return _basePositionMs.toDouble();
    final now = DateTime.now().millisecondsSinceEpoch;
    final delta = math.max(0, now - _lastPositionUpdateEpoch);
    return (_basePositionMs + delta).toDouble();
  }

  void _generateHarmonicFallback() {
    final songMs = _smoothSongMs;
    final beatRad = (songMs / 480.0) * math.pi * 2.0; // ~125 BPM quarter note
    final halfBeatRad = (songMs / 240.0) * math.pi * 2.0; // eighth note groove
    final barRad = (songMs / 1920.0) * math.pi * 2.0; // 4-beat phrase
    final flutterRad = (songMs / 160.0) * math.pi * 2.0; // percussion
    final shimmerRad = (songMs / 95.0) * math.pi * 2.0; // treble shimmer

    for (int i = 0; i < barCount; i++) {
      final norm = i / (barCount - 1); // 0 at bass, 1 at treble

      final beatSin = 0.5 + 0.5 * math.sin(beatRad);
      final kick = math.pow(beatSin, 3.2).toDouble() * 0.72;
      final subBass = (0.5 + 0.5 * math.sin(barRad - norm * 2.0)) * 0.35;
      final bassWeight = math.max(0.0, 1.0 - norm * 2.0);
      final bassComponent = (kick + subBass) * bassWeight;

      final midWave1 = 0.5 + 0.5 * math.sin(halfBeatRad - norm * 4.2);
      final midWave2 = 0.5 + 0.5 * math.cos(beatRad * 0.65 + norm * 2.8);
      final midWeight = math.sin(norm * math.pi);
      final midComponent = (midWave1 * 0.58 + midWave2 * 0.40) * midWeight;

      final hiHat =
          math.pow((0.5 + 0.5 * math.sin(flutterRad + norm * 5.8)), 2.0).toDouble() *
              0.75;
      final shimmer = (0.5 + 0.5 * math.cos(shimmerRad - norm * 8.2)) * 0.38;
      final trebleWeight = math.max(0.0, (norm - 0.35) * 1.54);
      final trebleComponent = (hiHat + shimmer) * trebleWeight;

      final eqCurve = 0.16 + (0.08 * math.sin(norm * math.pi));
      final bandResonance = 0.88 + 0.12 * math.sin(i * 19.37 + (songMs / 520.0));

      final energy =
          (eqCurve + bassComponent + midComponent + trebleComponent) * bandResonance;
      targetBins[i] = energy.clamp(0.06, 0.95);
    }
  }
}

/// Smooths a feed's band targets into bar heights: a snappy rise, gravity that
/// grows with height, a soft ceiling and a ghost peak that falls slowly. All
/// motion is time-based so it looks the same at any refresh rate.
///
/// Bars are mirrored around the centre: bar i and bar (23 - i) share a band,
/// so bass bulges in the middle and treble flutters at both edges.
class SpectrumPhysics {
  SpectrumPhysics();

  static const int barCount = VisualizerFeed.barCount;

  static const double _riseRate = 0.42; // attack lerp
  static const double _fallRate = 0.16; // base release lerp
  static const double _ceilingGravity = 0.30; // extra fall with height
  static const double _wallResistance = 0.50; // deceleration near the top
  static const double _trailDecay = 0.018; // ghost bar descent per frame

  final List<double> display = List<double>.filled(barCount, 0.0);
  final List<double> trail = List<double>.filled(barCount, 0.0);

  /// 0 when idle, 1 while playing. Bars grow in from nothing as it rises, and
  /// shrink away as it falls.
  double activity = 0.0;

  int _lastTickMs = DateTime.now().millisecondsSinceEpoch;

  /// Forget the time of the last step, for when ticking resumes after a pause
  /// so one long gap does not become one huge step.
  void resetClock() => _lastTickMs = DateTime.now().millisecondsSinceEpoch;

  /// Advances one tick. Returns true once the bars have settled at nothing
  /// and nothing is playing, which is when the caller may stop its ticker.
  bool step({required bool playing, required List<double> targets}) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dt = ((nowMs - _lastTickMs) / 1000.0).clamp(0.0, 0.1);
    _lastTickMs = nowMs;
    // A "60 fps frame" worth of time.
    final double k = (dt * 60.0).clamp(0.0, 1.0);

    final target = playing ? 1.0 : 0.0;
    if (activity != target) {
      final step = 0.04 * k;
      if (activity < target) {
        activity = math.min(target, activity + (step * 2.0));
      } else {
        activity = math.max(target, activity - step);
      }
      if (!playing && activity <= 0.001) {
        activity = 0.0;
      }
    }

    if (playing) {
      const double dMin = 1.0 / barCount;
      const double dMax = 1.0 - dMin;
      for (int i = 0; i < barCount; i++) {
        // 0.0 at the centre bar, 1.0 at the outermost, normalised so the full
        // band range is used.
        final d = ((i + 0.5) / barCount * 2.0 - 1.0).abs();
        final norm = ((d - dMin) / (dMax - dMin)).clamp(0.0, 1.0);
        final band = (norm * (barCount - 1)).round().clamp(0, barCount - 1);
        final targetVal = targets[band];

        double cur = display[i];
        if (targetVal > cur) {
          // Soft wall resistance: rising slows near the ceiling.
          double effRise = _riseRate;
          const double wallStart = 0.70;
          final proximity = ((cur - wallStart) / (1.0 - wallStart)).clamp(0.0, 1.0);
          effRise *= (1.0 - _wallResistance * proximity * proximity);
          cur += (targetVal - cur) * (effRise * k).clamp(0.0, 1.0);
        } else {
          // The higher a bar is, the faster it drops, so it does not stay
          // pinned at the top.
          final dynamicFall = (_fallRate + _ceilingGravity * cur).clamp(0.05, 0.95);
          cur += (targetVal - cur) * (dynamicFall * k).clamp(0.0, 1.0);
        }
        display[i] = cur.clamp(0.0, 1.0);

        // The ghost catches peaks at once and descends slowly.
        if (display[i] >= trail[i]) {
          trail[i] = display[i];
        } else {
          trail[i] = math.max(display[i], trail[i] - _trailDecay * k);
        }
      }
    } else {
      final double decayMul = math.pow(0.88, k).toDouble();
      for (int i = 0; i < barCount; i++) {
        display[i] = math.max(0.0, display[i] * decayMul - 0.015 * k);
        trail[i] = math.max(0.0, trail[i] * decayMul - 0.015 * k);
      }
    }

    return !playing && activity <= 0.0;
  }
}
