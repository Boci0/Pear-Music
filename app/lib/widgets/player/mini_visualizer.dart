import 'package:flutter/material.dart';

import '../../services/player_service.dart';
import '../../services/visualizer_feed.dart';

/// The visualizer as a quiet backdrop for the mini player: soft bars rising
/// from its bottom edge behind the title and controls, so the music is visible
/// outside the full player too.
///
/// It reads the same [VisualizerFeed] as the artwork visualizer and has its own
/// smoothing. It draws nothing at all while idle, repaints at about 30 fps (the
/// bar sits on a blurred glass surface, where every repaint costs more), and
/// its ticker parks whenever the app or window is not active.
class MiniVisualizer extends StatefulWidget {
  const MiniVisualizer({
    super.key,
    required this.player,
    required this.color,
  });

  final PlayerService player;

  /// The song's accent colour, already softened for controls.
  final Color color;

  @override
  State<MiniVisualizer> createState() => _MiniVisualizerState();
}

class _MiniVisualizerState extends State<MiniVisualizer>
    with SingleTickerProviderStateMixin {
  final VisualizerFeed _feed = VisualizerFeed.instance;
  final SpectrumPhysics _physics = SpectrumPhysics();
  late final AnimationController _ticker;
  final ValueNotifier<int> _paintTick = ValueNotifier<int>(0);

  static const int _minPaintGapMs = 30;
  int _lastPaintMs = 0;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_onTick);
    _feed.acquire(widget.player);
    _feed.changes.addListener(_syncTicker);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant MiniVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _feed.release();
      _feed.acquire(widget.player);
      _syncTicker();
    }
  }

  void _syncTicker() {
    if (!mounted) return;
    if ((widget.player.playing || _physics.activity > 0.0) &&
        _feed.renderActive) {
      if (!_ticker.isAnimating) {
        _physics.resetClock();
        _ticker.repeat();
      }
    } else if (_physics.activity <= 0.0 && _ticker.isAnimating) {
      _ticker.stop();
      _paintTick.value++;
    }
  }

  void _onTick() {
    if (!mounted) return;
    final playing = widget.player.playing && _feed.renderActive;
    _feed.refresh();
    final settled = _physics.step(playing: playing, targets: _feed.targetBins);
    if (settled) {
      _ticker.stop();
      _paintTick.value++;
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPaintMs >= _minPaintGapMs) {
      _lastPaintMs = now;
      _paintTick.value++;
    }
  }

  @override
  void dispose() {
    _feed.changes.removeListener(_syncTicker);
    _feed.release();
    _paintTick.dispose();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _MiniVisualizerPainter(
          color: widget.color,
          physics: _physics,
          repaint: _paintTick,
        ),
      ),
    );
  }
}

class _MiniVisualizerPainter extends CustomPainter {
  _MiniVisualizerPainter({
    required this.color,
    required this.physics,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final Color color;
  final SpectrumPhysics physics;

  @override
  void paint(Canvas canvas, Size size) {
    final act = physics.activity;
    if (act <= 0.003 || size.width <= 0 || size.height <= 0) return;

    const int bars = VisualizerFeed.barCount;
    const double gap = 3.0;
    final barWidth = ((size.width - gap * (bars - 1)) / bars).clamp(2.0, 9.0);
    final span = bars * barWidth + gap * (bars - 1);
    final startX = (size.width - span) / 2.0;
    final maxHeight = size.height * 0.78;
    final radius = Radius.circular(barWidth / 2.0);

    // Faint at the base and fainter at the tips: a texture behind the text,
    // not a second layer of content to read.
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          color.withValues(alpha: 0.26 * act),
          color.withValues(alpha: 0.10 * act),
        ],
      ).createShader(Rect.fromLTWH(0, size.height - maxHeight, size.width, maxHeight));

    for (var i = 0; i < bars; i++) {
      final amp = physics.display[i].clamp(0.0, 1.0);
      // A bar never quite disappears while playing, so the row reads as a row.
      final h = 3.0 + (maxHeight - 3.0) * amp * act;
      final x = startX + i * (barWidth + gap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - h, barWidth, h),
          radius,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MiniVisualizerPainter old) =>
      old.color != color || !identical(old.physics, physics);
}
