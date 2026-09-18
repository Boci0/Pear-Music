import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:system_audio_visualizer/system_audio_visualizer.dart';
import '../../services/player_service.dart';

/// An audio-reactive equalizer spectrum visualizer taking the full space of the album artwork.
/// Captures real-time audio output via WASAPI loopback with native FFT processing on Windows,
/// and falls back gracefully to harmonic frequency modeling on other platforms.
class ArtworkVisualizer extends StatefulWidget {
  final PlayerService player;
  final Color accentColor;
  final bool showBouncingPear;

  const ArtworkVisualizer({
    super.key,
    required this.player,
    required this.accentColor,
    this.showBouncingPear = false,
  });

  @override
  State<ArtworkVisualizer> createState() => _ArtworkVisualizerState();
}

class _ArtworkVisualizerState extends State<ArtworkVisualizer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const int barCount = 24;
  late final AnimationController _tickerController;
  int _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
  int _basePositionMs = 0;
  bool _isAppForeground = true;
  double _decayActivity = 0.0;

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

  // Bouncing Pear Physics State
  double _pearX = 0.0;
  double _pearY = -60.0;
  double _pearVx = 65.0;
  double _pearVy = 30.0;
  double _pearAngle = -0.2;
  double _pearOmega = 1.4;
  bool _pearInitialized = false;
  double _lastLayoutWidth = 0.0;
  double _lastLayoutHeight = 0.0;
  int _lastTickEpoch = DateTime.now().millisecondsSinceEpoch;
  final List<double> _prevDisplayBins = List<double>.filled(barCount, 0.0);

  // Dynamic Fake White Bar Poke System
  final List<double> _fakePokeHighlights = List<double>.filled(barCount, 0.0);
  final List<double> _fakePokeOffsets = List<double>.filled(barCount, 0.0);
  double _restDuration = 0.0;
  double _pokeCooldown = 0.8;

  void _resetPear(double width) {
    _pearX = width > 0 ? (width * 0.35) : 120.0;
    _pearY = -35.0;
    _pearVx = 70.0;
    _pearVy = 40.0;
    _pearAngle = -0.25;
    _pearOmega = 1.8;
    _pearInitialized = true;
    _restDuration = 0.0;
    _pokeCooldown = 0.8;
    _fakePokeHighlights.fillRange(0, barCount, 0.0);
    _fakePokeOffsets.fillRange(0, barCount, 0.0);
  }

  void _onArtworkTap(Offset localPos) {
    if (!widget.showBouncingPear) return;
    _restDuration = 0.0;
    final dx = _pearX - localPos.dx;
    final dy = _pearY - localPos.dy;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist < 90.0) {
      _pearVy = -480.0;
      _pearVx = (dx >= 0 ? 1 : -1) * 220.0;
      _pearOmega = (dx >= 0 ? 1 : -1) * 9.0;
    } else {
      _pearVy = -400.0;
      _pearVx += (dx > 0 ? -120.0 : 120.0);
      _pearOmega += (dx > 0 ? -4.0 : 4.0);
    }
    _syncTicker();
  }

  double get _computedStartX {
    if (_lastLayoutWidth <= 0) return 16.0;
    const int totalBars = 24;
    const double spacing = 4.0;
    const double horizontalPadding = 16.0;
    final availableWidth = _lastLayoutWidth - (horizontalPadding * 2.0);
    final barWidth = ((availableWidth - (spacing * (totalBars - 1))) / totalBars).clamp(3.0, 9.5);
    final totalSpan = (totalBars * barWidth) + (spacing * (totalBars - 1));
    return (_lastLayoutWidth - totalSpan) / 2.0;
  }

  @override
  void initState() {
    super.initState();
    _basePositionMs = widget.player.position?.inMilliseconds ?? 0;
    _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
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
    _syncTicker();
    if (widget.player.playing) {
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

  void _processFft(List<double> raw) {
    final rawLen = raw.length;
    if (rawLen == 0) return;

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
      }
      return;
    }

    // 2. Active Musical Spectrum Mapping (Standard Left-to-Right progression):
    // Bass on the left (bar 0), mids in center, treble on the right (bar 23).
    const int minMusicalBin = 6;
    const int maxMusicalBin = 48;
    final int span = math.min(rawLen - 1, maxMusicalBin) - minMusicalBin;

    for (int i = 0; i < barCount; i++) {
      final fracLow = (i / barCount).toDouble();
      final fracHigh = ((i + 1) / barCount).toDouble();

      final startIdx = (minMusicalBin + fracLow * span).floor().clamp(0, rawLen - 1);
      final endIdx = math.max(startIdx + 1, (minMusicalBin + fracHigh * (span + 1)).ceil().clamp(0, rawLen));

      double sum = 0.0;
      int count = 0;
      for (int j = startIdx; j < endIdx; j++) {
        sum += raw[j];
        count++;
      }
      final rawAmp = count > 0 ? (sum / count) : raw[startIdx];

      // Dynamic bin gate: require distinct acoustic presence
      const binNoiseGate = 0.03;
      if (rawAmp < binNoiseGate) {
        _targetBins[i] = 0.0;
        continue;
      }
      final gated = (rawAmp - binNoiseGate) / (1.0 - binNoiseGate);

      // Snappy target response so bars bounce crisply and come down immediately between beats
      final scaled = (gated * 1.15).clamp(0.0, 1.0);

      // Temporal damping to eliminate frame-to-frame jumpiness while preserving fast snappy drops
      final prev = _targetBins[i];
      final smoothed = scaled > prev ? prev + (scaled - prev) * 0.85 : prev + (scaled - prev) * 0.58;
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
      final kick = math.pow(beatSin, 3.2).toDouble() * 0.85;
      final subBass = (0.5 + 0.5 * math.sin(barRad - norm * 2.0)) * 0.40;
      final bassWeight = math.max(0.0, 1.0 - norm * 2.2);
      final bassComponent = (kick + subBass) * bassWeight;

      // 2. Mid frequencies melodic motion (i = 5..17)
      final midWave1 = 0.5 + 0.5 * math.sin(halfBeatRad - norm * 4.2);
      final midWave2 = 0.5 + 0.5 * math.cos(beatRad * 0.65 + norm * 2.8);
      final midWeight = math.sin(norm * math.pi);
      final midComponent = (midWave1 * 0.52 + midWave2 * 0.36) * midWeight;

      // 3. Treble shimmer and hi-hats on the right (i = 14..23)
      final hiHat = math.pow((0.5 + 0.5 * math.sin(flutterRad + norm * 5.8)), 2.0).toDouble() * 0.58;
      final shimmer = (0.5 + 0.5 * math.cos(shimmerRad - norm * 8.2)) * 0.26;
      final trebleWeight = math.max(0.0, (norm - 0.45) * 1.8);
      final trebleComponent = (hiHat + shimmer) * trebleWeight;

      // 4. Acoustic base curve
      final eqCurve = 0.16 + (0.10 * math.cos(norm * math.pi * 0.5));

      // 5. Per-band resonant variation
      final bandResonance = 0.85 + 0.15 * math.sin(i * 19.37 + (songMs / 520.0));

      final energy = (eqCurve + bassComponent + midComponent + trebleComponent) * bandResonance;
      final scaled = energy.clamp(0.06, 0.95);

      _targetBins[i] = scaled;
    }
  }

  void _onTick() {
    if (!mounted) return;

    final nowEpoch = DateTime.now().millisecondsSinceEpoch;
    final dtMs = math.min(45, math.max(1, nowEpoch - _lastTickEpoch));
    _lastTickEpoch = nowEpoch;
    final dt = dtMs / 1000.0;

    final isPlaying = widget.player.playing && _isAppForeground;
    final target = isPlaying ? 1.0 : 0.0;

    if (_decayActivity != target) {
      const step = 0.04;
      if (_decayActivity < target) {
        _decayActivity = math.min(target, _decayActivity + (step * 2.0));
      } else {
        _decayActivity = math.max(target, _decayActivity - step);
      }
      if (!widget.player.playing && _decayActivity <= 0.001) {
        _decayActivity = 0.0;
        final needsPhysics = widget.showBouncingPear &&
            (_pearVy.abs() > 2.0 || _pearY < (_lastLayoutHeight - 45.0));
        if (!needsPhysics) {
          _tickerController.stop();
          _stopCapture();
        }
      }
    }

    if (isPlaying) {
      if (!_hasNativeFft) {
        _generateHarmonicFallback();
      }

      // 5-point Gaussian spatial smoothing (fluid crests)
      final List<double> spatiallySmoothed = List<double>.filled(barCount, 0.0);
      for (int i = 0; i < barCount; i++) {
        final left2 = i > 1 ? _targetBins[i - 2] : (i > 0 ? _targetBins[i - 1] : _targetBins[i]);
        final left1 = i > 0 ? _targetBins[i - 1] : _targetBins[i];
        final center = _targetBins[i];
        final right1 = i < barCount - 1 ? _targetBins[i + 1] : _targetBins[i];
        final right2 = i < barCount - 2 ? _targetBins[i + 2] : (i < barCount - 1 ? _targetBins[i + 1] : _targetBins[i]);

        spatiallySmoothed[i] = (left2 * 0.08) + (left1 * 0.24) + (center * 0.36) + (right1 * 0.24) + (right2 * 0.08);
      }

      // Fluid, smooth motion ticker while preserving fast responsive drop
      for (int i = 0; i < barCount; i++) {
        final targetVal = spatiallySmoothed[i];
        final current = _displayBins[i];
        if (targetVal > current) {
          _displayBins[i] = current + (targetVal - current) * 0.28;
        } else {
          // Dynamic fall-down: drops smoothly towards lower target
          _displayBins[i] = current + (targetVal - current) * 0.18;
        }

        // Trailing buffer logic: catches peaks immediately, descends as a smooth lighter trail
        if (_displayBins[i] >= _trailBins[i]) {
          _trailBins[i] = _displayBins[i];
        } else {
          _trailBins[i] = math.max(_displayBins[i], _trailBins[i] - 0.012);
        }
      }
    } else {
      // Gentle decay to zero when paused
      for (int i = 0; i < barCount; i++) {
        _displayBins[i] = math.max(0.0, _displayBins[i] * 0.88 - 0.015);
        _trailBins[i] = math.max(0.0, _trailBins[i] * 0.88 - 0.015);
      }
    }

    // 2D Rigid-Body Physics Simulation for Bouncing Pear
    if (widget.showBouncingPear && _lastLayoutWidth > 0 && _lastLayoutHeight > 0) {
      final W = _lastLayoutWidth;
      final H = _lastLayoutHeight;
      final startX = _computedStartX;
      // Pear radius: diameter is sized a little larger than the side gap (startX) to the border
      // so it never slips down or gets wedged between the outer bar and the album frame
      final pearRadius = math.max(12.5, (startX + 6.0) / 2.0);
      const gravity = 1250.0;

      // Decay fake poke highlights & offsets, and cooldown
      _pokeCooldown = math.max(0.0, _pokeCooldown - dt);
      for (int i = 0; i < barCount; i++) {
        _fakePokeOffsets[i] = math.max(0.0, _fakePokeOffsets[i] - dt * 2.2);
        _fakePokeHighlights[i] = math.max(0.0, _fakePokeHighlights[i] - dt * 2.8);
      }

      // Gravity & air damping
      _pearVy += gravity * dt;
      _pearVx *= math.pow(0.992, dt * 60.0);
      _pearOmega *= math.pow(0.985, dt * 60.0);

      // Position and rotation integration
      _pearX += _pearVx * dt;
      _pearY += _pearVy * dt;
      _pearAngle += _pearOmega * dt;

      // Wall boundary reflections
      if (_pearX - pearRadius < 0) {
        _pearX = pearRadius;
        _pearVx = _pearVx.abs() * 0.82 + 20.0;
        _pearOmega = -_pearOmega * 0.70 + (_pearVy * 0.005);
      }
      if (_pearX + pearRadius > W) {
        _pearX = W - pearRadius;
        _pearVx = -_pearVx.abs() * 0.82 - 20.0;
        _pearOmega = -_pearOmega * 0.70 - (_pearVy * 0.005);
      }
      if (_pearY - pearRadius < 0) {
        _pearY = pearRadius;
        _pearVy = _pearVy.abs() * 0.80;
      }

      // Bar collision resolution across bottom equalizer
      const int totalBars = 24;
      const double spacing = 4.0;
      const double horizontalPadding = 16.0;
      final availableWidth = W - (horizontalPadding * 2.0);
      final barWidth = ((availableWidth - (spacing * (totalBars - 1))) / totalBars).clamp(3.0, 9.5);
      const double bottomPadding = 12.0;
      final maxBarHeight = H * 0.40;
      const double minBarHeight = 4.0;

      double highestBarSurfaceY = H - bottomPadding;
      int peakBarIndex = -1;
      double peakBarUpwardVel = 0.0;

      for (int i = 0; i < totalBars; i++) {
        final barLeft = startX + i * (barWidth + spacing);
        final barRight = barLeft + barWidth;

        if (barRight >= _pearX - pearRadius && barLeft <= _pearX + pearRadius) {
          final rawAmp = (i < _displayBins.length ? _displayBins[i] : 0.0) * _decayActivity;
          final pokeAmp = (i < _fakePokeOffsets.length ? _fakePokeOffsets[i] : 0.0);
          final amp = (rawAmp + pokeAmp).clamp(0.0, 1.0);

          final prevRaw = (i < _prevDisplayBins.length ? _prevDisplayBins[i] : 0.0) * _decayActivity;
          final prevAmp = prevRaw.clamp(0.0, 1.0);

          final barH = minBarHeight + (maxBarHeight - minBarHeight) * amp;
          final prevH = minBarHeight + (maxBarHeight - minBarHeight) * prevAmp;
          final barTopY = H - bottomPadding - barH;
          final upwardVel = dt > 0 ? (barH - prevH) / dt : 0.0;

          if (barTopY < highestBarSurfaceY) {
            highestBarSurfaceY = barTopY;
            peakBarIndex = i;
            peakBarUpwardVel = math.max(peakBarUpwardVel, upwardVel);
          }
        }
      }

      // Collision resolution with the highest bar surface
      if (_pearY + pearRadius >= highestBarSurfaceY) {
        _pearY = highestBarSurfaceY - pearRadius;

        // Only propel the pear upward if an equalizer bar is actively rising (poking it)
        if (peakBarUpwardVel > 25.0) {
          _pearVy = -math.max(_pearVy.abs() * 0.50, peakBarUpwardVel * 1.30);

          if (peakBarIndex >= 0) {
            final barCenter = startX + peakBarIndex * (barWidth + spacing) + (barWidth / 2.0);
            final offset = (_pearX - barCenter);
            _pearVx += (offset / pearRadius) * (peakBarUpwardVel * 0.35);
            _pearVx = _pearVx.clamp(-380.0, 380.0);
            _pearOmega += (offset / pearRadius) * (peakBarUpwardVel * 0.015);
            _pearOmega = _pearOmega.clamp(-15.0, 15.0);
          }
          _restDuration = 0.0;
        } else {
          // Stationary or descending bar: natural restitution and surface friction
          if (_pearVy > 40.0) {
            _pearVy = -_pearVy * 0.45;
          } else {
            // Settle to a complete stop when downward velocity is low
            _pearVy = 0.0;
          }
          _pearVx *= 0.88;
          if (_pearVx.abs() < 3.0) _pearVx = 0.0;
          _pearOmega *= 0.82;
          if (_pearOmega.abs() < 0.1) _pearOmega = 0.0;

          // Fake white bar poke:
          // When the pear lands or rests on quiet bars, poke it up with a white bar surge (only during active playback)
          if (widget.player.playing && peakBarIndex >= 0) {
            _restDuration += dt;
            if (_restDuration >= 0.30 && _pokeCooldown <= 0.0) {
              _restDuration = 0.0;
              _pokeCooldown = 1.8; // Controlled cooldown so it is not too frequent
              _fakePokeOffsets[peakBarIndex] = 0.65;
              _fakePokeHighlights[peakBarIndex] = 1.0;
              if (peakBarIndex > 0) {
                _fakePokeOffsets[peakBarIndex - 1] = 0.38;
                _fakePokeHighlights[peakBarIndex - 1] = 0.65;
              }
              if (peakBarIndex < totalBars - 1) {
                _fakePokeOffsets[peakBarIndex + 1] = 0.38;
                _fakePokeHighlights[peakBarIndex + 1] = 0.65;
              }
              // Direct impulse launch
              _pearVy = -380.0 - (math.Random().nextDouble() * 80.0);
              final flingDir = (peakBarIndex >= totalBars / 2) ? -1.0 : 1.0;
              _pearVx = flingDir * (140.0 + math.Random().nextDouble() * 70.0);
              _pearOmega = flingDir * 4.0;
            }
          } else if (!widget.player.playing) {
            _restDuration = 0.0;
          }
        }
      } else {
        _restDuration = 0.0;
      }

      // Floor boundary fallback
      final floorY = H - bottomPadding;
      if (_pearY + pearRadius >= floorY) {
        _pearY = floorY - pearRadius;
        if (_pearVy > 40.0) {
          _pearVy = -_pearVy * 0.45;
        } else {
          _pearVy = 0.0;
        }
        _pearVx *= 0.88;
        if (_pearVx.abs() < 3.0) _pearVx = 0.0;
        _pearOmega *= 0.82;
        if (_pearOmega.abs() < 0.1) _pearOmega = 0.0;

        // Also allow fake poke if resting on floor near the bars (only during active playback)
        if (widget.player.playing && _pokeCooldown <= 0.0) {
          final approxBar = ((_pearX - startX) / (barWidth + spacing)).round().clamp(0, totalBars - 1);
          _restDuration += dt;
          if (_restDuration >= 0.30) {
            _restDuration = 0.0;
            _pokeCooldown = 1.8;
            _fakePokeOffsets[approxBar] = 0.65;
            _fakePokeHighlights[approxBar] = 1.0;
            _pearVy = -380.0;
            final flingDir = (approxBar >= totalBars / 2) ? -1.0 : 1.0;
            _pearVx = flingDir * 150.0;
            _pearOmega = flingDir * 4.0;
          }
        } else if (!widget.player.playing) {
          _restDuration = 0.0;
        }
      }
    }

    for (int i = 0; i < barCount; i++) {
      _prevDisplayBins[i] = _displayBins[i];
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    if (_isAppForeground != isForeground) {
      _isAppForeground = isForeground;
      if (isForeground && widget.player.playing) {
        _startCapture();
      } else if (!isForeground) {
        _stopCapture();
      }
      _syncTicker();
    }
  }

  @override
  void didUpdateWidget(covariant ArtworkVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showBouncingPear != widget.showBouncingPear) {
      if (widget.showBouncingPear) {
        _resetPear(_lastLayoutWidth);
      }
      _syncTicker();
    }
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
    final hasActivePokes = _fakePokeHighlights.any((h) => h > 0.01) || _fakePokeOffsets.any((o) => o > 0.01);
    final needsPhysics = widget.showBouncingPear &&
        (_pearVy.abs() > 2.0 || _pearY < (_lastLayoutHeight - 45.0) || hasActivePokes);
    if ((widget.player.playing || _decayActivity > 0.0 || needsPhysics) && _isAppForeground) {
      if (!_tickerController.isAnimating) {
        _basePositionMs = widget.player.position?.inMilliseconds ?? 0;
        _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
        _lastTickEpoch = DateTime.now().millisecondsSinceEpoch;
        _tickerController.repeat();
      }
    } else {
      if (_decayActivity <= 0.0 && !needsPhysics && _tickerController.isAnimating) {
        _tickerController.stop();
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
      _restDuration = 0.0;
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
    return LayoutBuilder(
      builder: (context, constraints) {
        _lastLayoutWidth = constraints.maxWidth;
        _lastLayoutHeight = constraints.maxHeight;
        if (widget.showBouncingPear && !_pearInitialized && _lastLayoutWidth > 0) {
          _resetPear(_lastLayoutWidth);
        }

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: widget.showBouncingPear
              ? (details) => _onArtworkTap(details.localPosition)
              : null,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _tickerController,
              builder: (context, _) {
                final effectiveBins = [
                  for (int i = 0; i < barCount; i++)
                    ((_displayBins[i] + _fakePokeOffsets[i]) * _decayActivity).clamp(0.0, 1.0),
                ];
                return CustomPaint(
                  size: Size.infinite,
                  painter: _ArtworkVisualizerPainter(
                    songMs: _smoothSongMs,
                    isPlaying: widget.player.playing,
                    activity: _decayActivity,
                    accentColor: widget.accentColor,
                    liveBins: effectiveBins,
                    trailBins: _trailBins,
                    hasNativeFft: _hasNativeFft,
                    showBouncingPear: widget.showBouncingPear,
                    pearX: _pearX,
                    pearY: _pearY,
                    pearAngle: _pearAngle,
                    pearRadius: math.max(12.5, (_computedStartX + 6.0) / 2.0),
                    pokeHighlights: _fakePokeHighlights,
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _ArtworkVisualizerPainter extends CustomPainter {
  final double songMs;
  final bool isPlaying;
  final double activity;
  final Color accentColor;
  final List<double> liveBins;
  final List<double> trailBins;
  final bool hasNativeFft;
  final bool showBouncingPear;
  final double pearX;
  final double pearY;
  final double pearAngle;
  final double pearRadius;
  final List<double> pokeHighlights;

  static final Path _pearBodyPath = Path()
    ..moveTo(-10, 3)
    ..cubicTo(-11, 10, -6, 14, 0, 14)
    ..cubicTo(6, 14, 11, 10, 10, 3)
    ..cubicTo(9, -2, 6, -5, 5, -8)
    ..cubicTo(4, -12, -4, -12, -5, -8)
    ..cubicTo(-6, -5, -9, -2, -10, 3)
    ..close();

  static final Path _pearStemPath = Path()
    ..moveTo(0, -11)
    ..cubicTo(1, -15, 3, -17, 4, -18)
    ..cubicTo(5, -17.5, 2, -14, 0.8, -11)
    ..close();

  static final Path _pearLeafPath = Path()
    ..moveTo(2, -15)
    ..cubicTo(6, -19, 10, -18, 9, -14)
    ..cubicTo(6, -13, 4, -14, 2, -15)
    ..close();

  _ArtworkVisualizerPainter({
    required this.songMs,
    required this.isPlaying,
    required this.activity,
    required this.accentColor,
    required this.liveBins,
    required this.trailBins,
    required this.hasNativeFft,
    this.showBouncingPear = false,
    this.pearX = 0.0,
    this.pearY = 0.0,
    this.pearAngle = 0.0,
    this.pearRadius = 13.0,
    this.pokeHighlights = const [],
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // 1. Soft bottom-to-top vignette gradient across album artwork
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

    // 2. Multi-band Equalizer spectrum bars across full card width & height
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

    for (int i = 0; i < totalBars; i++) {
      double amp = 0.0;
      double trailAmp = 0.0;

      if (i < liveBins.length) {
        amp = liveBins[i].clamp(0.0, 1.0);
        trailAmp = (i < trailBins.length ? trailBins[i] : amp).clamp(0.0, 1.0);
      }

      final pokeAlpha = (i < pokeHighlights.length ? pokeHighlights[i] : 0.0).clamp(0.0, 1.0);
      final barX = startX + i * (barWidth + spacing);

      // 2a. Trailing buffer ghost bar (lighter tint, slow descent)
      if (trailAmp > amp) {
        final trailH = minBarHeight + (maxBarHeight - minBarHeight) * trailAmp * activity;
        final trailY = size.height - bottomPadding - trailH;
        final trailRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(barX, trailY, barWidth, trailH),
          Radius.circular(barWidth / 2.0),
        );
        final trailPaint = Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Color.lerp(accentColor, Colors.white, 0.45)!.withValues(alpha: 0.35 * activity),
              Colors.white.withValues(alpha: 0.55 * activity),
            ],
          ).createShader(Rect.fromLTWH(barX, trailY, barWidth, trailH));
        canvas.drawRRect(trailRect, trailPaint);
      }

      // 2b. Foreground active bar (gleaming white when actively poked beneath pear)
      final barH = minBarHeight + (maxBarHeight - minBarHeight) * amp * activity;
      final barY = size.height - bottomPadding - barH;

      final barRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(barX, barY, barWidth, barH),
        Radius.circular(barWidth / 2.0),
      );

      final barBottomColor = Color.lerp(
        accentColor.withValues(alpha: 0.78 + (0.18 * activity)),
        Colors.white,
        pokeAlpha * 0.85,
      )!;
      final barTopColor = Color.lerp(
        Color.lerp(accentColor, Colors.white, 0.50)!.withValues(alpha: 0.95),
        Colors.white,
        pokeAlpha,
      )!;

      final barPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            barBottomColor,
            barTopColor,
          ],
        ).createShader(Rect.fromLTWH(barX, barY, barWidth, barH));

      canvas.drawRRect(barRect, barPaint);

      // Subtle bright white rim when poked
      if (pokeAlpha > 0.15) {
        final whiteRimPaint = Paint()
          ..color = Colors.white.withValues(alpha: pokeAlpha * 0.75)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0;
        canvas.drawRRect(barRect, whiteRimPaint);
      }
    }

    // 3. 2D Bouncing Pear Rendering
    if (showBouncingPear && pearY > -40.0) {
      _drawPear(canvas, pearX, pearY, pearAngle, pearRadius);
    }
  }

  void _drawPear(Canvas canvas, double x, double y, double angle, double radius) {
    // Soft contact shadow on the bars or ground beneath pear
    final shadowY = y + radius * 0.88;
    final shadowRect = Rect.fromCenter(
      center: Offset(x, shadowY),
      width: radius * 1.8,
      height: radius * 0.60,
    );
    final shadowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.black.withValues(alpha: 0.45),
          Colors.transparent,
        ],
      ).createShader(shadowRect);
    canvas.drawOval(shadowRect, shadowPaint);

    // Vector pear with rotation
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(angle);

    final scale = radius / 13.0;
    canvas.scale(scale, scale);

    // Pear body gradient derived from the active track accent color
    final cHighlight = Color.lerp(accentColor, Colors.white, 0.70)!;
    final cBodyLight = Color.lerp(accentColor, Colors.white, 0.28)!;
    final cBodyMain = accentColor;
    final cBodyShade = Color.lerp(accentColor, Colors.black, 0.35)!;

    final bodyRect = Rect.fromLTWH(-12, -14, 24, 29);
    final bodyPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          cHighlight,
          cBodyLight,
          cBodyMain,
          cBodyShade,
        ],
        stops: const [0.0, 0.30, 0.70, 1.0],
      ).createShader(bodyRect)
      ..style = PaintingStyle.fill;

    canvas.drawPath(_pearBodyPath, bodyPaint);

    // Subtle pear stroke border
    final strokePaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    canvas.drawPath(_pearBodyPath, strokePaint);

    // Glossy specular highlight
    final highlightPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(-3.5, -4.0), width: 4.5, height: 7.5),
      highlightPaint,
    );

    // Stem with subtle accent warmth
    final stemPaint = Paint()
      ..color = Color.lerp(const Color(0xFF5D4037), accentColor, 0.20)!
      ..style = PaintingStyle.fill;
    canvas.drawPath(_pearStemPath, stemPaint);

    // Leaf harmonized with accent color
    final leafPaint = Paint()
      ..color = Color.lerp(accentColor, const Color(0xFF43A047), 0.35)!
      ..style = PaintingStyle.fill;
    canvas.drawPath(_pearLeafPath, leafPaint);

    final leafBorderPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    canvas.drawPath(_pearLeafPath, leafBorderPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ArtworkVisualizerPainter oldDelegate) {
    return oldDelegate.songMs != songMs ||
        oldDelegate.isPlaying != isPlaying ||
        oldDelegate.activity != activity ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.hasNativeFft != hasNativeFft ||
        oldDelegate.liveBins != liveBins ||
        oldDelegate.trailBins != trailBins ||
        oldDelegate.showBouncingPear != showBouncingPear ||
        oldDelegate.pearX != pearX ||
        oldDelegate.pearY != pearY ||
        oldDelegate.pearAngle != pearAngle ||
        oldDelegate.pearRadius != pearRadius ||
        oldDelegate.pokeHighlights != pokeHighlights;
  }
}

/// A crisp vector pear icon used for the bouncing pear button.
class MiniPearIconPainter extends CustomPainter {
  final Color color;
  const MiniPearIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final bodyPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(w * 0.28, h * 0.58);
    path.cubicTo(w * 0.20, h * 0.78, w * 0.35, h * 0.94, w * 0.50, h * 0.94);
    path.cubicTo(w * 0.65, h * 0.94, w * 0.80, h * 0.78, w * 0.72, h * 0.58);
    path.cubicTo(w * 0.68, h * 0.44, w * 0.62, h * 0.36, w * 0.60, h * 0.26);
    path.cubicTo(w * 0.58, h * 0.18, w * 0.42, h * 0.18, w * 0.40, h * 0.26);
    path.cubicTo(w * 0.38, h * 0.36, w * 0.32, h * 0.44, w * 0.28, h * 0.58);
    path.close();
    canvas.drawPath(path, bodyPaint);

    final stemPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    final stem = Path();
    stem.moveTo(w * 0.50, h * 0.22);
    stem.quadraticBezierTo(w * 0.54, h * 0.10, w * 0.64, h * 0.08);
    canvas.drawPath(stem, stemPaint);
  }

  @override
  bool shouldRepaint(covariant MiniPearIconPainter oldDelegate) => oldDelegate.color != color;
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
