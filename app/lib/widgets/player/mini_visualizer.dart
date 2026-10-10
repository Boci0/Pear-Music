import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/player_service.dart';
import '../../services/visualizer_feed.dart';

/// The visualizer as a quiet backdrop for the mini player: soft bars rising
/// from its bottom edge behind the title and controls, so the music is visible
/// outside the full player too.
///
/// It reads the same [VisualizerFeed] as the artwork visualizer and has its own
/// smoothing. It draws nothing at all while idle, updates about 20 times a
/// second (the bar sits on a blurred glass surface, where every repaint costs
/// more), shows only a real spectrum, and parks whenever the app or window is
/// not active.
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

class _MiniVisualizerState extends State<MiniVisualizer> {
  final VisualizerFeed _feed = VisualizerFeed.instance;
  final SpectrumPhysics _physics = SpectrumPhysics();
  final ValueNotifier<int> _paintTick = ValueNotifier<int>(0);

  /// A timer rather than a vsync ticker: a ticker wakes the UI thread at the
  /// display's rate (up to 144 Hz) and every frame re-draws the blurred glass
  /// this sits on, which on a phone cost about half a core. About 20 updates a
  /// second is plenty for bars behind text, and nothing runs between them.
  static const Duration _period = Duration(milliseconds: 50);
  Timer? _timer;

  /// False while a route covers this widget (the full player, a sheet): a
  /// covered widget is not drawn, so it should not be stepped either.
  bool _visible = true;

  /// How far the bars have grown in, 0..1. For tests.
  @visibleForTesting
  double get debugActivity => _physics.activity;

  @override
  void initState() {
    super.initState();
    _feed.acquire(widget.player);
    _feed.changes.addListener(_syncTimer);
    _syncTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _visible) {
      _visible = visible;
      _syncTimer();
    }
  }

  @override
  void didUpdateWidget(covariant MiniVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _feed.release();
      _feed.acquire(widget.player);
      _syncTimer();
    }
  }

  void _syncTimer() {
    if (!mounted) return;
    final want = ((widget.player.playing && _feed.hasNativeFft) ||
            _physics.activity > 0.0) &&
        _feed.renderActive &&
        _visible;
    if (want && _timer == null) {
      _physics.resetClock();
      _timer = Timer.periodic(_period, (_) => _onTick());
    } else if (!want && _physics.activity <= 0.0) {
      _stop();
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _paintTick.value++;
  }

  void _onTick() {
    if (!mounted) return;
    // Only the real spectrum is drawn here. The card may fall back to a made-up
    // pattern when there is no capture; behind the mini player that would be
    // bars dancing to nothing, so without a capture they simply fade away.
    final playing =
        widget.player.playing && _feed.renderActive && _feed.hasNativeFft;
    _feed.refresh();
    final settled = _physics.step(
      playing: playing,
      targets: _feed.targetBins,
      maxFrames: 4.0,
    );
    if (settled) {
      _stop();
      return;
    }
    _paintTick.value++;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _feed.changes.removeListener(_syncTimer);
    _feed.release();
    _paintTick.dispose();
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
