import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/player_service.dart';
import '../../services/visualizer_feed.dart';
import 'ribbon_paths.dart';

/// The visualizer as a quiet edge for the mini player: a thin wave along its
/// bottom edge, under the thumbnail and controls, so the music is visible
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

    // A thin wave along the pill's bottom edge, the same shape as the one on
    // the player card: low enough to sit under the thumbnail and controls and
    // clear of the title, so it is a texture on the edge, not a second layer
    // of content to read.
    final baseY = size.height - 3;
    final maxH = (size.height * 0.34).clamp(10.0, 22.0);
    final live = ribbonPoints(
      physics.display,
      width: size.width,
      baseY: baseY,
      maxHeight: maxH,
      padding: 0,
      floor: 1.5,
      scale: act,
    );
    if (live.length < 2) return;
    final ghost = ribbonPoints(
      physics.trail,
      width: size.width,
      baseY: baseY,
      maxHeight: maxH,
      padding: 0,
      floor: 1.5,
      scale: act,
    );
    final light = Color.lerp(color, Colors.white, 0.6)!;

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, baseY - maxH - 4, size.width, size.height));
    canvas.drawPath(
      ribbonCurve(ghost, closeAtY: baseY),
      Paint()..color = light.withValues(alpha: 0.10 * act),
    );
    canvas.drawPath(
      ribbonCurve(live, closeAtY: baseY),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            light.withValues(alpha: 0.50 * act),
            color.withValues(alpha: 0.18 * act),
          ],
        ).createShader(Rect.fromLTWH(0, baseY - maxH, size.width, maxH)),
    );
    canvas.drawPath(
      ribbonCurve(live),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white.withValues(alpha: 0.85 * act),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MiniVisualizerPainter old) =>
      old.color != color || !identical(old.physics, physics);
}
