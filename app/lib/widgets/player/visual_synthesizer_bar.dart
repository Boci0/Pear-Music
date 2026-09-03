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
  final double aura;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double>? onDragUpdate;
  final VoidCallback? onDragEnd;

  const VisualSynthesizerBar({
    super.key,
    required this.player,
    required this.currentPosition,
    required this.totalDuration,
    required this.aura,
    required this.onSeek,
    this.onDragUpdate,
    this.onDragEnd,
  });

  @override
  State<VisualSynthesizerBar> createState() => _VisualSynthesizerBarState();
}

class _VisualSynthesizerBarState extends State<VisualSynthesizerBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  double? _dragFraction;
  int _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
  int _basePositionMs = 0;

  @override
  void initState() {
    super.initState();
    _basePositionMs = widget.currentPosition.inMilliseconds;
    _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    if (widget.player.playing) {
      _ticker.repeat();
    }
    widget.player.addListener(_onPlayerStateChanged);
  }

  @override
  void didUpdateWidget(covariant VisualSynthesizerBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPosition != widget.currentPosition) {
      _basePositionMs = widget.currentPosition.inMilliseconds;
      _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
    }
  }

  void _onPlayerStateChanged() {
    if (widget.player.playing) {
      if (!_ticker.isAnimating) _ticker.repeat();
    } else {
      if (_ticker.isAnimating) _ticker.stop();
    }
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerStateChanged);
    _ticker.dispose();
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
                animation: _ticker,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _SynthesizerPainter(
                      displayFraction: displayFraction,
                      isPlaying: widget.player.playing,
                      aura: widget.aura,
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
  final double aura;
  final double songMs;
  final Color activeColor;
  final Color inactiveColor;
  final Color cursorColor;

  _SynthesizerPainter({
    required this.displayFraction,
    required this.isPlaying,
    required this.aura,
    required this.songMs,
    required this.activeColor,
    required this.inactiveColor,
    required this.cursorColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // Dynamically calculate total bars so they stretch 100% across the container width
    const targetBarWidth = 3.5;
    const minSpacing = 2.5;
    final totalBars = ((size.width + minSpacing) / (targetBarWidth + minSpacing))
        .floor()
        .clamp(20, 120);
    final barWidth = targetBarWidth;
    final spacing = totalBars > 1 ? (size.width - (totalBars * barWidth)) / (totalBars - 1) : 0.0;
    final maxHeight = size.height;
    const minHeight = 3.5;

    // Musical rhythm clocks derived directly from song playback position (BPM ~125):
    // 480ms per beat, 960ms half-measure, 1920ms full measure.
    final halfMeasureMs = songMs % 960.0;

    // Kick drum impact on beats 1 and 3 (downbeat): sharp attack, exponential decay
    final kickPhase = (halfMeasureMs < 480.0 ? halfMeasureMs : halfMeasureMs - 480.0) / 480.0;
    final kickImpact = isPlaying
        ? math.pow(math.max(0.0, 1.0 - (kickPhase * 2.6)), 2.8).toDouble()
        : 0.0;

    // Snare / clap impact on beats 2 and 4 (backbeat): 240ms offset in a 480ms cycle
    final snareOffsetMs = (songMs + 240.0) % 480.0;
    final snarePhase = snareOffsetMs / 480.0;
    final snareImpact = isPlaying
        ? math.pow(math.max(0.0, 1.0 - (snarePhase * 2.8)), 2.2).toDouble()
        : 0.0;

    // Hi-hat groove on 16th notes (120ms): crisp rapid ticks
    final hatPhase = (songMs % 120.0) / 120.0;
    final hatImpact = isPlaying
        ? math.pow(math.max(0.0, 1.0 - (hatPhase * 3.2)), 1.8).toDouble()
        : 0.0;

    // Organic chord swell across a 4-beat musical measure (1920ms)
    final barWave = 0.5 + 0.5 * math.sin((songMs / 1920.0) * math.pi * 2.0);

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.fill;

    final inactivePaint = Paint()
      ..color = inactiveColor
      ..style = PaintingStyle.fill;

    final cursorPaint = Paint()
      ..color = cursorColor
      ..style = PaintingStyle.fill;

    final currentBarIndex = (displayFraction * totalBars).floor().clamp(0, totalBars - 1);

    for (int i = 0; i < totalBars; i++) {
      final normX = i / (totalBars - 1);
      final x = i * (barWidth + spacing);

      // Spectrum analyzer weighting:
      // Bass region: left 30%
      // Mid-range / Vocals: center 40%
      // Treble / Percussion: right 30%
      final bassWeight = math.max(0.0, 1.0 - (normX / 0.35));
      final midWeight = math.max(0.0, 1.0 - ((normX - 0.5).abs() / 0.3));
      final trebleWeight = math.max(0.0, (normX - 0.6) / 0.4);

      // Deterministic per-bar frequency resonance peak
      final barResonance = 0.75 + 0.25 * math.sin(i * 1.85 + (songMs / 320.0));
      final staticEq = 0.22 + 0.32 * math.pow(normX - 0.48, 2);

      double heightRatio;
      if (isPlaying) {
        final dynamicPulse = (kickImpact * bassWeight * 0.95) +
            (snareImpact * midWeight * 0.75) +
            (hatImpact * trebleWeight * 0.65) +
            (barWave * 0.12);
        heightRatio = (staticEq + (dynamicPulse * barResonance * (0.6 + (aura * 0.4))))
            .clamp(0.10, 0.96);
      } else {
        heightRatio = (staticEq * 0.7).clamp(0.12, 0.55);
      }

      final barH = lerpDouble(minHeight, maxHeight, heightRatio)!;
      final top = (maxHeight - barH) / 2.0;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, top, barWidth, barH),
        Radius.circular(barWidth / 2.0),
      );

      if (i == currentBarIndex) {
        final cursorH = (barH + 5.0).clamp(minHeight, maxHeight);
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
        oldDelegate.songMs != songMs ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.cursorColor != cursorColor;
  }
}
