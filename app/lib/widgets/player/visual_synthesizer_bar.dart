import 'dart:async';
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
  State<VisualSynthesizerBar> createState() => _VisualSynthesizerBarState();
}

class _VisualSynthesizerBarState extends State<VisualSynthesizerBar> {
  Timer? _fpsTimer;
  double? _dragFraction;
  int _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
  int _basePositionMs = 0;

  @override
  void initState() {
    super.initState();
    _basePositionMs = widget.currentPosition.inMilliseconds;
    _lastPositionUpdateEpoch = DateTime.now().millisecondsSinceEpoch;
    widget.player.addListener(_onPlayerStateChanged);
    _syncTimer();
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
  }

  void _syncTimer() {
    if (widget.player.playing) {
      if (_fpsTimer == null || !_fpsTimer!.isActive) {
        _fpsTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
          if (mounted) setState(() {});
        });
      }
    } else {
      _fpsTimer?.cancel();
      _fpsTimer = null;
    }
  }

  void _onPlayerStateChanged() {
    _syncTimer();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerStateChanged);
    _fpsTimer?.cancel();
    _fpsTimer = null;
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
              child: CustomPaint(
                painter: _SynthesizerPainter(
                  displayFraction: displayFraction,
                  isPlaying: widget.player.playing,
                  aura: widget.aura,
                  enableGlow: widget.enableGlow,
                  songMs: _smoothSongMs,
                  activeColor: colorScheme.primary,
                  inactiveColor: colorScheme.onSurface.withValues(alpha: 0.15),
                  cursorColor: colorScheme.primary,
                ),
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
  final bool enableGlow;
  final double songMs;
  final Color activeColor;
  final Color inactiveColor;
  final Color cursorColor;

  _SynthesizerPainter({
    required this.displayFraction,
    required this.isPlaying,
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

    final beatRad = (songMs / 500.0) * math.pi * 2.0;
    final halfBeatRad = (songMs / 250.0) * math.pi * 2.0;
    final measureRad = (songMs / 2000.0) * math.pi * 2.0;

    final double beatSwell = isPlaying ? (0.5 + 0.5 * math.sin(beatRad)) : 0.0;
    final double measureSwell = isPlaying ? (0.5 + 0.5 * math.sin(measureRad)) : 0.0;

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

      final travelingWave1 = math.sin(beatRad - (normX * 2.5 * math.pi));
      final travelingWave2 = math.cos(halfBeatRad + (normX * 1.5 * math.pi));
      final bassPulse = math.sin(beatRad) * math.max(0.0, 1.0 - (normX * 2.2));
      final baseEq = 0.26 + (0.16 * math.sin(normX * math.pi));

      double heightRatio;
      if (isPlaying) {
        final motion = (travelingWave1 * 0.14) +
            (travelingWave2 * 0.08) +
            (bassPulse * 0.18 * beatSwell) +
            (measureSwell * 0.08);
        heightRatio = (baseEq + (motion * 0.70)).clamp(0.18, 0.82);
      } else {
        heightRatio = (baseEq * 0.70).clamp(0.15, 0.40);
      }

      final barH = lerpDouble(minHeight, maxHeight, heightRatio)!;
      final top = (maxHeight - barH) / 2.0;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, top, barWidth, barH),
        Radius.circular(barWidth / 2.0),
      );

      if (i == currentBarIndex) {
        final cursorH = (barH + 4.0).clamp(minHeight, maxHeight);
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
        oldDelegate.cursorColor != cursorColor;
  }
}
