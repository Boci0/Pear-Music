import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../services/player_service.dart';
import '../../services/visualizer_feed.dart';
import 'ribbon_paths.dart';

/// The visualizer as a quiet edge for the mini player: a thin wave along its
/// bottom edge, under the thumbnail and controls, so the music is visible
/// outside the full player too.
///
/// It reads the same [VisualizerFeed] as the artwork visualizer and has its own
/// smoothing. It draws nothing at all while idle, updates at up to 60 times a
/// second, shows only a real spectrum, and parks whenever the app is in the
/// background or minimized. An unfocused but visible window keeps it going.
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
  final ValueNotifier<int> _paintTick = ValueNotifier<int>(0);

  /// A vsync ticker, so the wave moves at the display's pace like the one on
  /// the card. Each frame re-draws the blurred glass this sits on, which is
  /// the cost of it: it was a 20 Hz timer before for that reason. Steps are at
  /// least [_minGapMs] apart, so a 120 or 144 Hz display is not driven faster
  /// than 60 Hz, and nothing runs while it is parked.
  late final Ticker _ticker = createTicker(_onFrame);
  static const int _minGapMs = 15;
  int _lastStepMs = 0;

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
    // The wave is there to be watched from the side while another window is
    // in use, so an unfocused window must not freeze it.
    _feed.holdWhileUnfocused();
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
    if (want && !_ticker.isActive) {
      _physics.resetClock();
      _lastStepMs = 0; // A started ticker counts from zero again.
      _ticker.start();
    } else if (!want && _physics.activity <= 0.0) {
      _stop();
    }
  }

  void _stop() {
    if (_ticker.isActive) _ticker.stop();
    _paintTick.value++;
  }

  void _onFrame(Duration elapsed) {
    final ms = elapsed.inMilliseconds;
    if (ms - _lastStepMs < _minGapMs) return;
    _lastStepMs = ms;
    _onTick();
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
    _ticker.dispose();
    _feed.changes.removeListener(_syncTimer);
    _feed.releaseUnfocusedHold();
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
    // Low enough that a loud crest stays under the title in a pill about 56 dp
    // tall (title bottom near 37 dp from the top).
    final maxH = (size.height * 0.24).clamp(8.0, 14.0);
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

    canvas.drawPath(
      ribbonCurve(ghost, closeAtY: size.height),
      Paint()..color = light.withValues(alpha: 0.10 * act),
    );
    canvas.drawPath(
      ribbonCurve(live, closeAtY: size.height),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            light.withValues(alpha: 0.32 * act),
            color.withValues(alpha: 0.14 * act),
          ],
        ).createShader(
          Rect.fromLTRB(0, baseY - maxH, size.width, size.height),
        ),
    );
    canvas.drawPath(
      ribbonCurve(live),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white.withValues(alpha: 0.60 * act),
    );
  }

  @override
  bool shouldRepaint(covariant _MiniVisualizerPainter old) =>
      old.color != color || !identical(old.physics, physics);
}
