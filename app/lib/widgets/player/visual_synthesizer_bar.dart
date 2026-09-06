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
                  final totalMs = widget.totalDuration.inMilliseconds.toDouble();
                  final currentMs = _smoothSongMs;
                  final actualFraction = (totalMs > 0 ? currentMs / totalMs : 0.0).clamp(0.0, 1.0);
                  final displayFraction = _dragFraction ?? actualFraction;

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

    // Helper: linearly interpolate amplitude envelope at any fraction [0.0, 1.0]
    double sampleWf(double fraction) {
      if (!hasWaveform) return 0.22;
      final fIdx = (fraction * (wf.length - 1)).clamp(0.0, (wf.length - 1).toDouble());
      final base = fIdx.floor();
      final next = (base + 1).clamp(0, wf.length - 1);
      final t = fIdx - base;
      return (lerpDouble(wf[base], wf[next], t) ?? wf[base]).clamp(0.0, 1.0);
    }

    // Instantaneous audio energy and transient beat kick at current playback position
    final currentEnergy = sampleWf(displayFraction);
    final prevEnergy = sampleWf((displayFraction - 0.012).clamp(0.0, 1.0));
    final transientKick = math.max(0.0, currentEnergy - prevEnergy);

    // Constant harmonic period divisor (1200ms) guarantees 100% mathematical phase continuity
    // with zero phase jumps, zero twitching, and zero erratic behavior.
    final fluidPhase = (songMs / 1200.0) * math.pi * 2.0;

    for (int i = 0; i < totalBars; i++) {
      final normX = i / (totalBars - 1);
      final x = i * (barWidth + spacing);

      // Authentic acoustic loudness of each bar across the timeline of the song
      final rawPeak = hasWaveform
          ? sampleWf(normX)
          : (0.18 + (0.12 * math.sin(normX * math.pi)));
      final baseHeightRatio = (0.08 + (rawPeak * 0.72)).clamp(0.08, 0.88);

      double heightRatio;
      if (i == currentBarIndex) {
        // The playhead cursor bar: actively surges up and down with the current energy and beat transient
        final cursorPulse = isPlaying
            ? ((currentEnergy * 0.35) + (transientKick * 0.50))
            : 0.0;
        heightRatio = (baseHeightRatio + 0.12 + cursorPulse).clamp(0.14, 0.98);
      } else if (i < currentBarIndex) {
        // Played bars: show their authentic waveform profile with a gentle, energy-scaled fluid ripple
        final wave = 0.5 + 0.5 * math.sin(fluidPhase - (normX * 3.5));
        final activeRipple = isPlaying ? (wave * currentEnergy * 0.14) : 0.0;
        heightRatio = (baseHeightRatio + activeRipple).clamp(0.08, 0.92);
      } else {
        // Unplayed upcoming bars: display true acoustic preview of the track
        heightRatio = baseHeightRatio;
      }

      final barH = lerpDouble(minHeight, maxHeight, heightRatio)!;
      final top = (maxHeight - barH) / 2.0;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, top, barWidth, barH),
        Radius.circular(barWidth / 2.0),
      );

      if (i == currentBarIndex) {
        canvas.drawRRect(rect, cursorPaint);
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
