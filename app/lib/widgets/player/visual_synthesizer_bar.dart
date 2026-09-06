import 'dart:math' as math;
import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';
import '../../services/player_service.dart';

/// An interactive, beat-reactive visualizer bar chart that functions as a scrubbable progress bar.
/// Calculates rhythmic harmonic amplitude over time so that bars pump and undulate to the beat
/// rather than jittering randomly.
class VisualSynthesizerBar extends StatefulWidget {
  final PlayerService player;
  final Duration currentPosition;
  final Duration totalDuration;
  final List<double>? waveform;
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
    this.waveform,
    this.aura = 0.0,
    this.enableGlow = false,
    required this.onSeek,
    this.onDragUpdate,
    this.onDragEnd,
  });

  @override
  State<VisualSynthesizerBar> createState() => _VisualSynthesizerBarState();
}

class _VisualSynthesizerBarState extends State<VisualSynthesizerBar>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _tickerController;
  double? _dragFraction;
  int _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
  int _basePositionMs = 0;
  bool _isAppForeground = true;

  @override
  void initState() {
    super.initState();
    _basePositionMs = widget.currentPosition.inMilliseconds;
    _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
    _tickerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    WidgetsBinding.instance.addObserver(this);
    widget.player.addListener(_onPlayerStateChanged);
    _syncTicker();
    widget.player.ensureWaveformLoaded();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    if (_isAppForeground != isForeground) {
      _isAppForeground = isForeground;
      _syncTicker();
    }
  }

  @override
  void didUpdateWidget(covariant VisualSynthesizerBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerStateChanged);
      widget.player.addListener(_onPlayerStateChanged);
      _onPlayerStateChanged();
    }
    if (oldWidget.currentPosition != widget.currentPosition) {
      _basePositionMs = widget.currentPosition.inMilliseconds;
      _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
    }
    widget.player.ensureWaveformLoaded();
  }

  void _syncTicker() {
    if (widget.player.playing && _isAppForeground) {
      if (!_tickerController.isAnimating) {
        _tickerController.repeat();
      }
    } else {
      if (_tickerController.isAnimating) {
        _tickerController.stop();
      }
    }
  }

  void _onPlayerStateChanged() {
    _syncTicker();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
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
    final delta = (now - _lastPositionUpdateEpoch).clamp(0, 1000);
    return (_basePositionMs + delta).toDouble();
  }

  void _handleDragUpdate(Offset localPosition, double width) {
    if (width <= 0) return;
    final frac = (localPosition.dx / width).clamp(0.0, 1.0);
    setState(() => _dragFraction = frac);
    final totalMs = widget.totalDuration.inMilliseconds.toDouble();
    if (totalMs > 0) {
      widget.onDragUpdate?.call(frac * totalMs);
    }
  }

  void _handleDragEnd() {
    if (_dragFraction != null) {
      final totalMs = widget.totalDuration.inMilliseconds;
      if (totalMs > 0) {
        final seekMs = (_dragFraction! * totalMs).round();
        widget.onSeek(Duration(milliseconds: seekMs));
      }
      setState(() => _dragFraction = null);
    }
    widget.onDragEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final totalMs = widget.totalDuration.inMilliseconds.toDouble();
    final currentMs = widget.currentPosition.inMilliseconds.toDouble();
    final actualFraction = (totalMs > 0 ? currentMs / totalMs : 0.0).clamp(0.0, 1.0);
    final displayFraction = _dragFraction ?? actualFraction;

    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (details) => _handleDragUpdate(details.localPosition, width),
            onHorizontalDragUpdate: (details) => _handleDragUpdate(details.localPosition, width),
            onHorizontalDragEnd: (_) => _handleDragEnd(),
            onHorizontalDragCancel: () {
              setState(() => _dragFraction = null);
              widget.onDragEnd?.call();
            },
            onTapDown: (details) {
              _handleDragUpdate(details.localPosition, width);
              _handleDragEnd();
            },
            child: SizedBox(
              height: 44,
              width: double.infinity,
              child: AnimatedBuilder(
                animation: _tickerController,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _SynthesizerPainter(
                      displayFraction: displayFraction,
                      isPlaying: widget.player.playing,
                      waveform: widget.waveform ?? widget.player.currentWaveform,
                      aura: widget.aura,
                      enableGlow: widget.enableGlow,
                      songMs: _smoothSongMs,
                      activeColor: colorScheme.primary,
                      inactiveColor: colorScheme.onSurface.withValues(alpha: 0.15),
                      cursorColor: colorScheme.primary,
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SynthesizerPainter extends CustomPainter {
  final double displayFraction;
  final bool isPlaying;
  final List<double>? waveform;
  final double aura;
  final bool enableGlow;
  final double songMs;
  final Color activeColor;
  final Color inactiveColor;
  final Color cursorColor;

  static final Paint _activePaint = Paint()..style = PaintingStyle.fill;
  static final Paint _inactivePaint = Paint()..style = PaintingStyle.fill;
  static final Paint _cursorPaint = Paint()..style = PaintingStyle.fill;

  _SynthesizerPainter({
    required this.displayFraction,
    required this.isPlaying,
    this.waveform,
    required this.aura,
    required this.enableGlow,
    required this.songMs,
    required this.activeColor,
    required this.inactiveColor,
    required this.cursorColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // Dynamically calculate total bars (16 to 42 bars maximum to preserve GPU and CPU bounds)
    const targetBarWidth = 4.0;
    const minSpacing = 3.0;
    final totalBars = ((size.width + minSpacing) / (targetBarWidth + minSpacing))
        .floor()
        .clamp(16, 42);
    final barWidth = targetBarWidth;
    final spacing = totalBars > 1 ? (size.width - (totalBars * barWidth)) / (totalBars - 1) : 0.0;
    final maxHeight = size.height;
    const minHeight = 3.5;

    final activePaint = _activePaint..color = activeColor;
    final inactivePaint = _inactivePaint..color = inactiveColor;
    final cursorPaint = _cursorPaint..color = cursorColor;

    final currentBarIndex = (displayFraction * totalBars).floor().clamp(0, totalBars - 1);

    final wf = waveform;
    final hasWaveform = wf != null && wf.isNotEmpty;

    // Real-time audio energy and beat transient sampled at current playback position
    double instantLoudness = 0.55;
    double transientKick = 0.0;
    if (hasWaveform) {
      final curWfIdx = (displayFraction * (wf.length - 1)).clamp(0.0, (wf.length - 1).toDouble());
      final baseIdx = curWfIdx.floor();
      final frac = curWfIdx - baseIdx;
      final nextIdx = (baseIdx + 1).clamp(0, wf.length - 1);
      final prevIdx = (baseIdx - 1).clamp(0, wf.length - 1);
      instantLoudness = (lerpDouble(wf[baseIdx], wf[nextIdx], frac) ?? wf[baseIdx]).clamp(0.0, 1.0);
      transientKick = math.max(0.0, instantLoudness - wf[prevIdx]);
    }

    final double overallEnergy = hasWaveform
        ? (0.18 + (0.82 * instantLoudness) + (transientKick * 0.45)).clamp(0.12, 1.0)
        : 0.65;

    for (int i = 0; i < totalBars; i++) {
      final normX = i / (totalBars - 1);
      final x = i * (barWidth + spacing);

      // Real-time multi-band frequency bouncing:
      // Bass band (low frequencies, punchy kick drum rebound on left bars)
      final bassPhase = (songMs / 185.0) * math.pi * 2.0;
      final bassWave = math.pow(math.max(0.0, math.sin(bassPhase - (i * 0.38))), 1.8).toDouble();

      // Mid band (vocals, instruments, snare bounce in center bars)
      final midPhase = (songMs / 118.0) * math.pi * 2.0;
      final midWave = math.pow(math.max(0.0, math.sin(midPhase + (i * 0.78))), 1.5).toDouble();

      // Treble band (hi-hats, percussive shimmer on right bars)
      final treblePhase = (songMs / 68.0) * math.pi * 2.0;
      final trebleWave = math.pow(math.max(0.0, math.cos(treblePhase - (i * 1.28))), 1.3).toDouble();

      // Frequency distribution across the spectrum
      final bassWeight = math.max(0.0, 1.0 - (normX * 1.65));
      final midWeight = math.sin(normX * math.pi);
      final trebleWeight = math.max(0.0, (normX - 0.25) * 1.35);

      // Individual bar resonance seed so adjacent bars bounce independently
      final barResonance = 0.68 + (0.32 * math.sin(i * 3.82 + 0.95));

      final bandActivity = (bassWave * bassWeight * 1.15) +
          (midWave * midWeight * 0.95) +
          (trebleWave * trebleWeight * 0.80);

      // Raw dynamic bounce height reacting directly to the current song loudness and transient
      final dynamicBounce = bandActivity * barResonance * overallEnergy;

      double heightRatio;
      if (isPlaying) {
        // Dramatic vertical travel: actively moves up and down between 0.10 and 0.95
        heightRatio = (0.10 + (dynamicBounce * 0.85)).clamp(0.08, 0.96);
      } else {
        // When paused or stopped: clean minimal resting baseline
        heightRatio = 0.08;
      }

      final barH = lerpDouble(minHeight, maxHeight, heightRatio)!;
      final top = (maxHeight - barH) / 2.0;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, top, barWidth, barH),
        Radius.circular(barWidth / 2.0),
      );

      if (i == currentBarIndex) {
        final cursorExtra = isPlaying ? (4.0 + 4.0 * overallEnergy) : 4.0;
        final cursorH = (barH + cursorExtra).clamp(minHeight, maxHeight);
        final cursorTop = (maxHeight - cursorH) / 2.0;
        final cursorRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, cursorTop, barWidth, cursorH),
          Radius.circular(barWidth / 2.0),
        );
        canvas.drawRRect(cursorRect, cursorPaint);
      } else if (i < currentBarIndex) {
        canvas.drawRRect(rect, activePaint);
      } else {
        canvas.drawRRect(rect, inactivePaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SynthesizerPainter oldDelegate) {
    return oldDelegate.displayFraction != displayFraction ||
        oldDelegate.isPlaying != isPlaying ||
        oldDelegate.aura != aura ||
        oldDelegate.enableGlow != enableGlow ||
        oldDelegate.songMs != songMs ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.cursorColor != cursorColor ||
        oldDelegate.waveform != waveform;
  }
}
