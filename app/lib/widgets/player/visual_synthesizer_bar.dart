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

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    if (widget.player.playing) {
      _ticker.repeat();
    }
    widget.player.addListener(_onPlayerStateChanged);
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
                  final nowMs = DateTime.now().millisecondsSinceEpoch.toDouble();
                  return CustomPaint(
                    painter: _SynthesizerPainter(
                      displayFraction: displayFraction,
                      isPlaying: widget.player.playing,
                      aura: widget.aura,
                      posMs: currentMs,
                      timeMs: nowMs,
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
  final double posMs;
  final double timeMs;
  final Color activeColor;
  final Color inactiveColor;
  final Color cursorColor;

  static const int barCount = 42;

  _SynthesizerPainter({
    required this.displayFraction,
    required this.isPlaying,
    required this.aura,
    required this.posMs,
    required this.timeMs,
    required this.activeColor,
    required this.inactiveColor,
    required this.cursorColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final totalBars = barCount;
    final spacing = 2.0;
    final availableWidth = size.width - ((totalBars - 1) * spacing);
    final barWidth = (availableWidth / totalBars).clamp(1.5, 6.0);
    final maxHeight = size.height;
    final minHeight = 4.0;

    // Rhythmic beat clock: 125 BPM fundamental beat (~480ms per beat)
    final beatPhase = (timeMs / 480.0) * math.pi * 2.0;
    final halfBeat = (timeMs / 240.0) * math.pi * 2.0;
    final double beatIntensity = isPlaying ? (0.65 + (0.35 * math.sin(beatPhase))) : 0.0;

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

      // Multi-harmonic spectrum synthesizer:
      // Bass frequencies (left) emphasize deep beat drops.
      // Mid frequencies (center) carry vocal harmonics.
      // Treble frequencies (right) shimmer with faster subdivision rhythm.
      final bassWeight = (1.0 - normX).clamp(0.0, 1.0);
      final trebleWeight = normX.clamp(0.0, 1.0);

      final bassMod = math.sin(beatPhase + (normX * math.pi)) * bassWeight;
      final midMod = math.sin(halfBeat + (normX * 4.0 * math.pi)) * 0.4;
      final trebleMod = math.cos((timeMs / 160.0) * math.pi * 2.0 + (normX * 6.0)) * trebleWeight * 0.3;

      // Base static EQ curve (smiling curve: bass punch, clean mid dip, crisp highs)
      final staticEq = 0.28 + (0.35 * math.pow(normX - 0.45, 2));

      // Combine static curve with live rhythmic beat modulation
      double heightRatio = staticEq + ((bassMod + midMod + trebleMod) * 0.38 * beatIntensity * (0.5 + aura * 0.5));
      if (!isPlaying) {
        // Calm resting level when paused
        heightRatio = staticEq * 0.65;
      }
      heightRatio = heightRatio.clamp(0.12, 0.95);

      final barH = lerpDouble(minHeight, maxHeight, heightRatio)!;
      final top = (maxHeight - barH) / 2.0;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, top, barWidth, barH),
        Radius.circular(barWidth / 2.0),
      );

      if (i == currentBarIndex) {
        // Cursor bar: slightly taller with glowing accent
        final cursorTop = (maxHeight - (barH + 4.0).clamp(minHeight, maxHeight)) / 2.0;
        final cursorRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, cursorTop, barWidth, (barH + 4.0).clamp(minHeight, maxHeight)),
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
        oldDelegate.posMs != posMs ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor;
  }
}
