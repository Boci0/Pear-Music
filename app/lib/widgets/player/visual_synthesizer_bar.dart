import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:system_audio_visualizer/system_audio_visualizer.dart';
import '../../services/player_service.dart';
import '../../services/window_focus.dart';

/// An audio-reactive "butterfly" spectrum visualizer taking the full space of the album artwork.
/// Bars are mirrored around the centre: the bass bulges from the middle and the
/// treble flutters on both outer edges, so the spectrum always looks balanced
/// (no more left-heavy bias). Physics are time-based (frame-rate independent)
/// with a snappy rise, altitude gravity, a soft ceiling and ghost peak trails.
/// Native FFT on Windows/Android, harmonic modeling fallback.
class ArtworkVisualizer extends StatefulWidget {
  final PlayerService player;
  final Color accentColor;

  const ArtworkVisualizer({
    super.key,
    required this.player,
    required this.accentColor,
  });

  @override
  State<ArtworkVisualizer> createState() => _ArtworkVisualizerState();
}

class _ArtworkVisualizerState extends State<ArtworkVisualizer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const int barCount = 24;
  late final AnimationController _tickerController;
  int _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
  int _lastTickMs = DateTime.now().millisecondsSinceEpoch;
  int _basePositionMs = 0;
  bool _isAppForeground = true;
  bool _windowFocused = true;
  double _decayActivity = 0.0;

  /// Repaint gate: the canvas repaints on every tick, so the bars move at the
  /// display's refresh rate instead of a stepped 30 fps. Repaints stay cheap
  /// because the painter shares one gradient shader across all bars per frame,
  /// and the whole ticker parks whenever the window is unfocused or paused.
  final ValueNotifier<int> _paintTick = ValueNotifier<int>(0);

  StreamSubscription<List<double>>? _fftSub;
  StreamSubscription<Duration>? _positionSub;
  final List<double> _targetBins = List<double>.filled(barCount, 0.0);
  final List<double> _displayBins = List<double>.filled(barCount, 0.0);
  final List<double> _trailBins = List<double>.filled(barCount, 0.0);
  static const _androidChannel = MethodChannel('com.peerm.peerm_app/visualizer');
  static const _androidStream = EventChannel('com.peerm.peerm_app/visualizer_stream');

  bool _hasNativeFft = false;
  bool _wasapiRunning = false;
  bool _androidRunning = false;
  int? _currentBoundSessionId;
  StreamSubscription? _androidSub;
  StreamSubscription<int?>? _sessionIdSub;

  // Slow per-bar loudness average used by the auto-gain ("leveling") stage so
  // quiet bands still contribute movement.
  final List<double> _bandAvg = List<double>.filled(barCount, 0.0);

  // Precomputed FFT band edges and high-frequency compensation, rebuilt only
  // when the incoming bin count changes so the per-callback mapping loop does
  // no pow() work.
  int _mappedRawLen = -1;
  final List<int> _bandStart = List<int>.filled(barCount, 0);
  final List<int> _bandEnd = List<int>.filled(barCount, 1);
  final List<double> _bandHfComp = List<double>.filled(barCount, 1.0);

  // Butterfly bar physics constants ("per 60 fps frame" values, applied ×k to
  // stay frame-rate independent).
  static const double _riseRate = 0.42; // attack lerp
  static const double _fallRate = 0.16; // base release lerp
  static const double _ceilingGravity = 0.30; // extra fall with height
  static const double _wallResistance = 0.50; // deceleration near the top
  static const double _trailDecay = 0.018; // ghost bar descent per frame

  @override
  void initState() {
    super.initState();
    _basePositionMs = widget.player.position?.inMilliseconds ?? 0;
    _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
    _lastTickMs = DateTime.now().millisecondsSinceEpoch;
    _decayActivity = widget.player.playing ? 1.0 : 0.0;
    _positionSub = widget.player.positionStream.listen((pos) {
      _basePositionMs = pos.inMilliseconds;
      _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
    });
    _tickerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_onTick);
    WidgetsBinding.instance.addObserver(this);
    widget.player.addListener(_onPlayerStateChanged);
    _windowFocused = WindowFocus.focused.value;
    WindowFocus.focused.addListener(_onWindowFocusChanged);
    _syncTicker();
    if (widget.player.playing && _renderActive) {
      _startCapture();
    }
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
    for (int i = 0; i < barCount; i++) {
      _bandAvg[i] = 0.0;
    }
  }

  Future<void> _startAndroidCapture() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      var status = await Permission.microphone.status;
      if (!status.isGranted) {
        status = await Permission.microphone.request();
      }
      if (!status.isGranted) {
        _hasNativeFft = false;
        return;
      }

      if (!mounted || !widget.player.playing) return;

      _androidSub ??= _androidStream.receiveBroadcastStream().listen(
        (raw) {
          if (!mounted) return;
          if (raw is List && raw.isNotEmpty) {
            final bins = raw.map((e) => (e as num).toDouble()).toList();
            _hasNativeFft = true;
            _processFft(bins);
          }
        },
        onError: (_) {
          _hasNativeFft = false;
        },
      );

      _sessionIdSub?.cancel();
      _sessionIdSub = widget.player.androidAudioSessionIdStream.listen((newId) {
        if (!mounted || !widget.player.playing) return;
        final target = (newId != null && newId > 0) ? newId : 0;
        if (target != _currentBoundSessionId) {
          _bindAndroidSession(target);
        }
      });

      final currentId = widget.player.androidAudioSessionId;
      final initialTarget = (currentId != null && currentId > 0) ? currentId : 0;
      await _bindAndroidSession(initialTarget);
    } catch (_) {
      _hasNativeFft = false;
    }
  }

  Future<void> _bindAndroidSession(int sessionId) async {
    if (_currentBoundSessionId == sessionId && _androidRunning) return;
    try {
      final success = await _androidChannel.invokeMethod<bool>('start', {'sessionId': sessionId}) ?? false;
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
          if (!mounted) return;
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
  /// the current bin count. Called on every FFT callback but only does work
  /// when the bin count changed, keeping the mapping loop free of pow() math.
  void _rebuildBandMap(int rawLen) {
    if (_mappedRawLen == rawLen) return;
    _mappedRawLen = rawLen;
    final int minMusicalBin = math.min(3, math.max(0, rawLen - 12)).toInt();
    final int maxMusicalBin = math.min(56, math.max(8, rawLen - 1)).toInt();
    final int span = math.max(1, math.min(rawLen - 1, maxMusicalBin) - minMusicalBin).toInt();
    const double warp = 1.15;
    const double tilt = 1.40;
    for (int i = 0; i < barCount; i++) {
      final fracLow = math.pow(i / barCount, warp).toDouble();
      final fracHigh = math.pow((i + 1) / barCount, warp).toDouble();
      final startIdx = (minMusicalBin + fracLow * span).floor().clamp(0, rawLen - 1);
      _bandStart[i] = startIdx;
      _bandEnd[i] = math.max(startIdx + 1, (minMusicalBin + fracHigh * (span + 1)).ceil().clamp(0, rawLen));
      _bandHfComp[i] = 1.0 + tilt * math.pow(i / (barCount - 1), 0.85).toDouble();
    }
  }

  void _processFft(List<double> raw) {
    final rawLen = raw.length;
    if (rawLen == 0) return;

    _rebuildBandMap(rawLen);

    // 1. Global Silence Detection:
    // When a track is paused, between songs, or in silent intros/breakdowns,
    // WASAPI loopback still returns minute digital quantization noise.
    // We compute total energy and peak across all bins; if below audible volume,
    // shut off all target bins immediately so nothing moves.
    double maxRaw = 0.0;
    double sumRaw = 0.0;
    for (int k = 0; k < rawLen; k++) {
      final v = raw[k];
      sumRaw += v;
      if (v > maxRaw) maxRaw = v;
    }
    final meanRaw = sumRaw / rawLen;

    // If max energy is below 0.08 or average below 0.02, it is absolute silence
    if (maxRaw < 0.08 || meanRaw < 0.020) {
      for (int i = 0; i < barCount; i++) {
        _targetBins[i] = 0.0;
        _bandAvg[i] *= 0.97;
      }
      return;
    }

    // 2. Active Musical Spectrum Mapping:
    // Band 0 = bass, band 23 = treble. Octave-warped so low/mid frequencies
    // don't dominate the lower bands, with progressive high-frequency
    // compensation for natural acoustic balance. Band edges and the HF
    // compensation curve come from _rebuildBandMap, computed once per bin
    // count instead of per callback.
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

      // Dynamic bin gate: require distinct acoustic presence
      if (rawAmp < binNoiseGate) {
        _targetBins[i] = 0.0;
        _bandAvg[i] *= 0.997;
        continue;
      }
      final gated = (rawAmp - binNoiseGate) / math.max(0.001, (1.0 - binNoiseGate));

      // Progressive high-frequency compensation counteracts acoustic pink noise rolloff
      final scaled = (gated * gain * _bandHfComp[i]).clamp(0.0, 1.0);

      // Per-band auto-gain blends the absolute amplitude with the band's level
      // relative to its own slow average so quiet bands still contribute.
      const double leveling = 0.50;
      double mixed = scaled;
      if (leveling > 0.001) {
        final leveled = (scaled / (_bandAvg[i] * 1.6 + 0.004)).clamp(0.0, 1.0);
        mixed = scaled * (1.0 - leveling) + leveled * leveling;
      }
      _bandAvg[i] = _bandAvg[i] * 0.992 + scaled * 0.008;

      // Temporal damping keeps the derived targets stable and musical.
      final prev = _targetBins[i];
      final smoothed = mixed > prev ? prev + (mixed - prev) * 0.85 : prev + (mixed - prev) * 0.58;
      _targetBins[i] = smoothed;
    }
  }

  void _generateHarmonicFallback() {
    final songMs = _smoothSongMs;
    // Multi-tempo musical rhythms
    final beatRad = (songMs / 480.0) * math.pi * 2.0; // ~125 BPM quarter note beat
    final halfBeatRad = (songMs / 240.0) * math.pi * 2.0; // eighth note groove
    final barRad = (songMs / 1920.0) * math.pi * 2.0; // 4-beat measure phrase
    final flutterRad = (songMs / 160.0) * math.pi * 2.0; // triplet/percussion
    final shimmerRad = (songMs / 95.0) * math.pi * 2.0; // treble shimmer

    for (int i = 0; i < barCount; i++) {
      final norm = i / (barCount - 1); // 0 at left (bass), 1 at right (treble)

      // 1. Bass / Sub-bass punch on the left (i = 0..5)
      final beatSin = 0.5 + 0.5 * math.sin(beatRad);
      final kick = math.pow(beatSin, 3.2).toDouble() * 0.72;
      final subBass = (0.5 + 0.5 * math.sin(barRad - norm * 2.0)) * 0.35;
      final bassWeight = math.max(0.0, 1.0 - norm * 2.0);
      final bassComponent = (kick + subBass) * bassWeight;

      // 2. Mid frequencies melodic motion (i = 5..17)
      final midWave1 = 0.5 + 0.5 * math.sin(halfBeatRad - norm * 4.2);
      final midWave2 = 0.5 + 0.5 * math.cos(beatRad * 0.65 + norm * 2.8);
      final midWeight = math.sin(norm * math.pi);
      final midComponent = (midWave1 * 0.58 + midWave2 * 0.40) * midWeight;

      // 3. Treble shimmer and hi-hats on the right (i = 12..23)
      final hiHat = math.pow((0.5 + 0.5 * math.sin(flutterRad + norm * 5.8)), 2.0).toDouble() * 0.75;
      final shimmer = (0.5 + 0.5 * math.cos(shimmerRad - norm * 8.2)) * 0.38;
      final trebleWeight = math.max(0.0, (norm - 0.35) * 1.54);
      final trebleComponent = (hiHat + shimmer) * trebleWeight;

      // 4. Acoustic base curve with even floor distribution
      final eqCurve = 0.16 + (0.08 * math.sin(norm * math.pi));

      // 5. Per-band resonant variation
      final bandResonance = 0.88 + 0.12 * math.sin(i * 19.37 + (songMs / 520.0));

      final energy = (eqCurve + bassComponent + midComponent + trebleComponent) * bandResonance;
      final scaled = energy.clamp(0.06, 0.95);

      _targetBins[i] = scaled;
    }
  }

  void _onTick() {
    if (!mounted) return;

    // Frame-rate independent time step: all motion below is scaled by [k]
    // (a "60 fps frame" worth of time), so the bars move at the same real
    // speed at any display refresh rate and do not speed up/slow down when
    // the device throttles frames while idle.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dt = ((nowMs - _lastTickMs) / 1000.0).clamp(0.0, 0.1);
    _lastTickMs = nowMs;
    final double k = (dt * 60.0).clamp(0.0, 1.0);

    final isPlaying = widget.player.playing && _renderActive;
    final target = isPlaying ? 1.0 : 0.0;

    if (_decayActivity != target) {
      final step = 0.04 * k;
      if (_decayActivity < target) {
        _decayActivity = math.min(target, _decayActivity + (step * 2.0));
      } else {
        _decayActivity = math.max(target, _decayActivity - step);
      }
      // Stop the ticker whenever rendering is inactive (paused, backgrounded
      // or unfocused), not only when playback itself stopped.
      if (!isPlaying && _decayActivity <= 0.001) {
        _decayActivity = 0.0;
        _tickerController.stop();
        _stopCapture();
        _requestPaint();
      }
    }

    if (isPlaying) {
      if (!_hasNativeFft) {
        _generateHarmonicFallback();
      }

      // ---- Butterfly bars motion (time-based) ------------------------------
      // Bars are mirrored around the centre: bar i and bar (23-i) share the same
      // frequency band, so bass bulges in the middle and treble flutters on
      // both edges, keeping the look symmetric and balanced.
      for (int i = 0; i < barCount; i++) {
        // 0.0 at the centre bar, 1.0 at the outermost bar, normalised so the
        // full band range is used: the centre carries the sub-bass and the
        // outer edges carry the top treble.
        const double dMin = 1.0 / barCount; // innermost bar
        const double dMax = 1.0 - dMin; // outermost bar
        final d = ((i + 0.5) / barCount * 2.0 - 1.0).abs();
        final norm = ((d - dMin) / (dMax - dMin)).clamp(0.0, 1.0);
        final band = (norm * (barCount - 1)).round().clamp(0, barCount - 1);
        final targetVal = _targetBins[band];

        double cur = _displayBins[i];

        if (targetVal > cur) {
          // Soft wall resistance: rising slows down the closer the bar gets to
          // the ceiling, as if the top of the visualizer is pushing it back.
          double effRise = _riseRate;
          const double wallStart = 0.70;
          final proximity = ((cur - wallStart) / (1.0 - wallStart)).clamp(0.0, 1.0);
          effRise *= (1.0 - _wallResistance * proximity * proximity);
          cur += (targetVal - cur) * (effRise * k).clamp(0.0, 1.0);
        } else {
          // Dynamic fall: the higher the bar is, the faster it drops so it
          // does not stay pinned at the top.
          final dynamicFall = (_fallRate + _ceilingGravity * cur).clamp(0.05, 0.95);
          cur += (targetVal - cur) * (dynamicFall * k).clamp(0.0, 1.0);
        }

        _displayBins[i] = cur.clamp(0.0, 1.0);

        // Trailing buffer logic: catches peaks immediately, descends as a
        // smooth lighter ghost bar.
        if (_displayBins[i] >= _trailBins[i]) {
          _trailBins[i] = _displayBins[i];
        } else {
          _trailBins[i] = math.max(_displayBins[i], _trailBins[i] - _trailDecay * k);
        }
      }
    } else {
      // Gentle decay to zero when paused
      final double decayMul = math.pow(0.88, k).toDouble();
      for (int i = 0; i < barCount; i++) {
        _displayBins[i] = math.max(0.0, _displayBins[i] * decayMul - 0.015 * k);
        _trailBins[i] = math.max(0.0, _trailBins[i] * decayMul - 0.015 * k);
      }
    }

    // Repaint on every tick (display refresh rate). This used to be throttled
    // to ~30 fps because the full-rate spectrum repaint was the heaviest
    // continuous cost; the painter now reuses a single gradient shader for all
    // bars, so full-rate repaints stay cheap and the motion reads as fluid.
    _requestPaint();
  }

  void _requestPaint() {
    _paintTick.value++;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    if (_isAppForeground != isForeground) {
      _isAppForeground = isForeground;
      _applyRenderActivity();
    }
  }

  void _onWindowFocusChanged() {
    final focused = WindowFocus.focused.value;
    if (_windowFocused == focused) return;
    _windowFocused = focused;
    _applyRenderActivity();
  }

  /// True when the app is in the foreground and the window is the active one.
  bool get _renderActive => _isAppForeground && _windowFocused;

  /// Reconciles capture + ticker state after a foreground or focus change.
  void _applyRenderActivity() {
    if (_renderActive && widget.player.playing) {
      _startCapture();
    } else if (!_renderActive) {
      _stopCapture();
    }
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant ArtworkVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerStateChanged);
      _positionSub?.cancel();
      widget.player.addListener(_onPlayerStateChanged);
      _positionSub = widget.player.positionStream.listen((pos) {
        _basePositionMs = pos.inMilliseconds;
        _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
      });
      _onPlayerStateChanged();
    }
  }

  void _syncTicker() {
    if ((widget.player.playing || _decayActivity > 0.0) && _renderActive) {
      if (!_tickerController.isAnimating) {
        _basePositionMs = widget.player.position?.inMilliseconds ?? 0;
        _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
        _lastTickMs = DateTime.now().millisecondsSinceEpoch;
        _tickerController.repeat();
      }
    } else {
      if (_decayActivity <= 0.0 && _tickerController.isAnimating) {
        _tickerController.stop();
        _requestPaint();
      }
    }
  }

  void _onPlayerStateChanged() {
    if (widget.player.playing) {
      _basePositionMs = widget.player.position?.inMilliseconds ?? 0;
      _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
      _startCapture();
    } else {
      _stopCapture();
    }
    _syncTicker();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _stopCapture();
    _positionSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.player.removeListener(_onPlayerStateChanged);
    WindowFocus.focused.removeListener(_onWindowFocusChanged);
    _paintTick.dispose();
    _tickerController.dispose();
    super.dispose();
  }

  double get _smoothSongMs {
    if (!widget.player.playing) {
      return _basePositionMs.toDouble();
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final delta = math.max(0, now - _lastPositionUpdateEpoch);
    return (_basePositionMs + delta).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Static backdrop layer: rendered once and cached, so the per-frame
          // spectrum repaint never rebuilds the vignette gradient.
          const RepaintBoundary(
            child: CustomPaint(painter: _VignettePainter()),
          ),
          // No AnimatedBuilder here: repaints are driven by [_paintTick] (the
          // ~30 fps gate) through the painter's repaint listenable, so the
          // widget tree is not rebuilt on every frame.
          CustomPaint(
            size: Size.infinite,
            willChange: true,
            painter: _ArtworkVisualizerPainter(
              accentColor: widget.accentColor,
              activity: () => _decayActivity,
              liveBins: _displayBins,
              trailBins: _trailBins,
              repaint: _paintTick,
            ),
          ),
        ],
      ),
    );
  }
}

/// Static backdrop for the visualizer: the bottom vignette gradient, kept in
/// a const painter behind its own RepaintBoundary layer so it is drawn once
/// instead of on every animation frame.
class _VignettePainter extends CustomPainter {
  const _VignettePainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final vignetteRect = Rect.fromLTWH(0, size.height * 0.45, size.width, size.height * 0.55);
    final vignettePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          Colors.black.withValues(alpha: 0.50),
          Colors.black.withValues(alpha: 0.18),
          Colors.transparent,
        ],
        stops: const [0.0, 0.65, 1.0],
      ).createShader(vignetteRect);
    canvas.drawRect(vignetteRect, vignettePaint);
  }

  @override
  bool shouldRepaint(covariant _VignettePainter oldDelegate) => false;
}

class _ArtworkVisualizerPainter extends CustomPainter {
  final Color accentColor;

  /// Read at paint time because the value keeps decaying between rebuilds.
  final double Function() activity;
  final List<double> liveBins;
  final List<double> trailBins;

  _ArtworkVisualizerPainter({
    required this.accentColor,
    required this.activity,
    required this.liveBins,
    required this.trailBins,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final act = activity();

    // Mirrored "butterfly" spectrum bars across the full card width
    const int totalBars = 24;
    const double spacing = 4.0;
    const double horizontalPadding = 16.0;
    final availableWidth = size.width - (horizontalPadding * 2.0);
    final barWidth = ((availableWidth - (spacing * (totalBars - 1))) / totalBars).clamp(3.0, 9.5);
    final totalSpan = (totalBars * barWidth) + (spacing * (totalBars - 1));
    final startX = (size.width - totalSpan) / 2.0;

    const double bottomPadding = 12.0;
    final maxBarHeight = size.height * 0.40;
    const double minBarHeight = 4.0;

    final radius = Radius.circular(barWidth / 2.0);
    final barBottomColor = accentColor.withValues(alpha: 0.78 + (0.18 * act));
    final barTopColor = Color.lerp(accentColor, Colors.white, 0.50)!.withValues(alpha: 0.95);

    // One shader per frame for the whole bar band instead of one per bar:
    // every bar is anchored at the band's bottom, so a shared vertical
    // gradient still runs from the accent base up to the white tip, and tall
    // bars reach further into the light. This drops ~48 createShader calls per
    // frame down to two, which is what makes full-rate repaints affordable.
    final bandRect = Rect.fromLTWH(
      0,
      size.height - bottomPadding - maxBarHeight,
      size.width,
      maxBarHeight,
    );
    final barGradient = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [barBottomColor, barTopColor],
    );
    final trailGradient = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [
        Color.lerp(accentColor, Colors.white, 0.45)!.withValues(alpha: 0.35 * act),
        Colors.white.withValues(alpha: 0.55 * act),
      ],
    );

    // Two reusable paints, each with a shared shader, for all bars per frame.
    final trailPaint = Paint()..shader = trailGradient.createShader(bandRect);
    final barPaint = Paint()..shader = barGradient.createShader(bandRect);

    for (int i = 0; i < totalBars; i++) {
      double amp = 0.0;
      double trailAmp = 0.0;

      if (i < liveBins.length) {
        amp = liveBins[i].clamp(0.0, 1.0);
        trailAmp = (i < trailBins.length ? trailBins[i] : amp).clamp(0.0, 1.0);
      }

      final barX = startX + i * (barWidth + spacing);

      // Trailing buffer ghost bar (lighter tint, slow descent). Skip ghosts
      // that barely peek above the live bar; they only cost a draw.
      if (trailAmp > amp) {
        final trailH = minBarHeight + (maxBarHeight - minBarHeight) * trailAmp * act;
        if (trailH > minBarHeight + 2.0) {
          final trailY = size.height - bottomPadding - trailH;
          final trailRect = RRect.fromRectAndRadius(
            Rect.fromLTWH(barX, trailY, barWidth, trailH),
            radius,
          );
          canvas.drawRRect(trailRect, trailPaint);
        }
      }

      // Foreground active bar
      final barH = minBarHeight + (maxBarHeight - minBarHeight) * amp * act;
      final barY = size.height - bottomPadding - barH;

      final barRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(barX, barY, barWidth, barH),
        radius,
      );

      canvas.drawRRect(barRect, barPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ArtworkVisualizerPainter oldDelegate) {
    return oldDelegate.accentColor != accentColor;
  }
}

/// Legacy progress-bar visualizer kept for compatibility.
class VisualSynthesizerBar extends StatelessWidget {
  final PlayerService player;
  final Duration currentPosition;
  final Duration totalDuration;
  final double aura;
  final bool enableGlow;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double>? onDragUpdate;
  final VoidCallback? onDragEnd;

  const VisualSynthesizerBar({
    super.key,
    required this.player,
    required this.currentPosition,
    required this.totalDuration,
    this.aura = 0.0,
    this.enableGlow = false,
    required this.onSeek,
    this.onDragUpdate,
    this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
