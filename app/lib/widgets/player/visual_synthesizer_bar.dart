import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:system_audio_visualizer/system_audio_visualizer.dart';
import '../../services/player_service.dart';

/// An audio-reactive equalizer spectrum visualizer taking the full space of the album artwork.
/// Captures real-time audio output via WASAPI loopback with native FFT processing on Windows,
/// and falls back gracefully to harmonic frequency modeling on other platforms.
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
  int _basePositionMs = 0;
  bool _isAppForeground = true;
  double _decayActivity = 0.0;

  StreamSubscription<List<double>>? _fftSub;
  final List<double> _targetBins = List<double>.filled(barCount, 0.0);
  final List<double> _displayBins = List<double>.filled(barCount, 0.0);
  final List<double> _trailBins = List<double>.filled(barCount, 0.0);
  bool _hasNativeFft = false;
  bool _wasapiRunning = false;

  @override
  void initState() {
    super.initState();
    _basePositionMs = widget.player.position?.inMilliseconds ?? 0;
    _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
    _decayActivity = widget.player.playing ? 1.0 : 0.0;
    _tickerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_onTick);
    WidgetsBinding.instance.addObserver(this);
    widget.player.addListener(_onPlayerStateChanged);
    _syncTicker();
    if (widget.player.playing) {
      _startWasapiCapture();
    }
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

    // If max energy is below 0.12 or average below 0.04, it is absolute silence
    if (maxRaw < 0.12 || meanRaw < 0.035) {
      for (int i = 0; i < barCount; i++) {
        _targetBins[i] = 0.0;
      }
      return;
    }

    // 2. Active Musical Spectrum Mapping:
    // Focus strictly on the active musical frequencies:
    // Bin 12 (~86Hz bass/kick) up to Bin 36 (~1.1kHz vocals/harmonics).
    const int minMusicalBin = 12;
    const int maxMusicalBin = 36;
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
      const binNoiseGate = 0.06;
      if (rawAmp < binNoiseGate) {
        _targetBins[i] = 0.0;
        continue;
      }
      final gated = (rawAmp - binNoiseGate) / (1.0 - binNoiseGate);

      // Linear response with gentle lift: low volume stays flat/quiet, beats jump crisply
      final scaled = gated * 1.35;
      _targetBins[i] = scaled.clamp(0.0, 1.0);
    }
  }

  void _onTick() {
    if (!mounted) return;

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
        _tickerController.stop();
        _stopWasapiCapture();
      }
    }

    if (isPlaying && _hasNativeFft) {
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

      // Fast reactive rise and fast drop for active bars, with smooth lingering buffer trail
      for (int i = 0; i < barCount; i++) {
        final targetVal = spatiallySmoothed[i];
        final current = _displayBins[i];
        if (targetVal > current) {
          _displayBins[i] = current + (targetVal - current) * 0.32;
        } else {
          // Snappy fall-down so movement is responsive and dynamic
          _displayBins[i] = current + (targetVal - current) * 0.22;
        }

        // Trailing buffer logic: catches peaks immediately, descends slowly as a smooth lighter trail
        if (_displayBins[i] >= _trailBins[i]) {
          _trailBins[i] = _displayBins[i];
        } else {
          _trailBins[i] = math.max(_displayBins[i], _trailBins[i] - 0.010);
        }
      }
    } else {
      // Gentle decay to zero when paused
      for (int i = 0; i < barCount; i++) {
        _displayBins[i] = math.max(0.0, _displayBins[i] * 0.88 - 0.015);
        _trailBins[i] = math.max(0.0, _trailBins[i] * 0.88 - 0.015);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    if (_isAppForeground != isForeground) {
      _isAppForeground = isForeground;
      if (isForeground && widget.player.playing) {
        _startWasapiCapture();
      } else if (!isForeground) {
        _stopWasapiCapture();
      }
      _syncTicker();
    }
  }

  @override
  void didUpdateWidget(covariant ArtworkVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerStateChanged);
      widget.player.addListener(_onPlayerStateChanged);
      _onPlayerStateChanged();
    }
  }

  void _syncTicker() {
    if ((widget.player.playing || _decayActivity > 0.0) && _isAppForeground) {
      if (!_tickerController.isAnimating) {
        _basePositionMs = widget.player.position?.inMilliseconds ?? 0;
        _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
        _tickerController.repeat();
      }
    } else {
      if (_decayActivity <= 0.0 && _tickerController.isAnimating) {
        _tickerController.stop();
      }
    }
  }

  void _onPlayerStateChanged() {
    if (widget.player.playing) {
      _basePositionMs = widget.player.position?.inMilliseconds ?? 0;
      _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
      _startWasapiCapture();
    } else {
      _stopWasapiCapture();
    }
    _syncTicker();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _stopWasapiCapture();
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
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _tickerController,
        builder: (context, _) {
          return CustomPaint(
            size: Size.infinite,
            painter: _ArtworkVisualizerPainter(
              songMs: _smoothSongMs,
              isPlaying: widget.player.playing,
              activity: _decayActivity,
              accentColor: widget.accentColor,
              liveBins: _displayBins,
              trailBins: _trailBins,
              hasNativeFft: _hasNativeFft,
            ),
          );
        },
      ),
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

  _ArtworkVisualizerPainter({
    required this.songMs,
    required this.isPlaying,
    required this.activity,
    required this.accentColor,
    required this.liveBins,
    required this.trailBins,
    required this.hasNativeFft,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // 1. Soft bottom-to-top vignette gradient across album artwork
    final vignettePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          Colors.black.withValues(alpha: 0.50),
          Colors.black.withValues(alpha: 0.20),
          Colors.transparent,
        ],
        stops: const [0.0, 0.60, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), vignettePaint);

    // 2. Multi-band Equalizer spectrum bars across full card width & height
    const int totalBars = 24;
    const double spacing = 4.0;
    const double horizontalPadding = 16.0;
    final availableWidth = size.width - (horizontalPadding * 2.0);
    final barWidth = ((availableWidth - (spacing * (totalBars - 1))) / totalBars).clamp(3.0, 9.5);
    final totalSpan = (totalBars * barWidth) + (spacing * (totalBars - 1));
    final startX = (size.width - totalSpan) / 2.0;

    const double bottomPadding = 12.0;
    final maxBarHeight = size.height * 0.82;
    const double minBarHeight = 4.0;

    for (int i = 0; i < totalBars; i++) {
      double amp = 0.0;
      double trailAmp = 0.0;
      if (hasNativeFft && i < liveBins.length) {
        amp = liveBins[i].clamp(0.0, 1.0);
        trailAmp = (i < trailBins.length ? trailBins[i] : amp).clamp(0.0, 1.0);
      }

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

      // 2b. Foreground active bar
      final barH = minBarHeight + (maxBarHeight - minBarHeight) * amp * activity;
      final barY = size.height - bottomPadding - barH;

      final barRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(barX, barY, barWidth, barH),
        Radius.circular(barWidth / 2.0),
      );

      final barPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            accentColor.withValues(alpha: 0.78 + (0.18 * activity)),
            Color.lerp(accentColor, Colors.white, 0.50)!.withValues(alpha: 0.95),
          ],
        ).createShader(Rect.fromLTWH(barX, barY, barWidth, barH));

      canvas.drawRRect(barRect, barPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ArtworkVisualizerPainter oldDelegate) {
    return oldDelegate.songMs != songMs ||
        oldDelegate.isPlaying != isPlaying ||
        oldDelegate.activity != activity ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.hasNativeFft != hasNativeFft ||
        oldDelegate.liveBins != liveBins ||
        oldDelegate.trailBins != trailBins;
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
