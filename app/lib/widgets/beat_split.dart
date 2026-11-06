import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../services/player_service.dart';
import '../services/visualizer_feed.dart';

/// Turns a band into a 0..1 hit level: a hit louder than the recent average
/// jumps the level up, then it falls away smoothly, so a steady bass line
/// does not keep the colours split.
class BeatEnvelope {
  BeatEnvelope({this.gain = 2.5, this.decay = 0.88});

  /// How strongly a hit above the average counts. Low enough that a soft kick
  /// gives a small split and only a hard one reaches the top.
  final double gain;

  /// What is left of the level after one 60 Hz frame.
  final double decay;

  double _avg = 0;
  double level = 0;

  /// True when the last [step] started a new hit rather than decaying one.
  bool hit = false;

  /// [bass] is 0..1; [frames] is how many 60 Hz frames passed since the last step.
  double step(double bass, double frames) {
    final f = frames.clamp(0.0, 4.0);
    _avg += (bass - _avg) * (1 - math.pow(0.94, f));
    final onset = ((bass - _avg - 0.04) * gain).clamp(0.0, 1.0);
    final decayed = level * math.pow(decay, f);
    hit = onset > decayed + 0.15;
    level = math.max(onset, decayed);
    if (level < 0.01) level = 0;
    return level;
  }

  void reset() {
    _avg = 0;
    level = 0;
    hit = false;
  }
}

/// Wraps the whole app: on kicks and snares it splits red and blue apart
/// across the window, most at the edges like a lens, and lets them fade back.
///
/// The colour split works on every renderer: on a hit the app is snapshotted
/// once and red and blue copies of it are added over the app, pulled apart.
/// Between hits there is no snapshot and nothing extra is drawn.
///
/// It is always in the tree and keeps the same shape when idle, so turning it
/// on or off never rebuilds the app under it. While off, paused or parked it
/// runs no ticker.
class BeatSplit extends StatefulWidget {
  const BeatSplit({
    super.key,
    required this.enabled,
    required this.player,
    required this.child,
  });

  final bool enabled;
  final PlayerService? player;
  final Widget child;

  @override
  State<BeatSplit> createState() => _BeatSplitState();
}

class _BeatSplitState extends State<BeatSplit>
    with SingleTickerProviderStateMixin {
  static const double _maxSplitPx = 18;
  // Lens fringing: red spreads and blue pulls in by this share of the size, so
  // the middle stays clean and the edges split most, like a real lens.
  static const double _maxRadial = 0.016;

  final VisualizerFeed _feed = VisualizerFeed.instance;
  final BeatEnvelope _kick = BeatEnvelope();
  // Snares and claps sit in the low mids. Faster to fade than a kick.
  final BeatEnvelope _snare = BeatEnvelope(gain: 3, decay: 0.84);
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  final GlobalKey _boundary = GlobalKey();
  final math.Random _rng = math.Random();
  // Between beats a plain timer listens, which draws nothing. The frame ticker
  // runs only from a hit until the split has faded: on Windows every ticker
  // frame redraws the whole window, so a ticker running through the whole
  // song cost a full redraw 60 times a second for nothing.
  late final Ticker _ticker = createTicker(_onFrame);
  Timer? _listen;
  Duration _lastTick = Duration.zero;
  Offset _splitDir = const Offset(1, 0);
  double _shownKick = 0;
  double _shownSnare = 0;
  bool _acquired = false;
  bool _calm = false;
  ui.Image? _frame;

  /// For tests: how far the colours are split, 0..1.
  @visibleForTesting
  double get debugSplit => _split;

  @override
  void initState() {
    super.initState();
    _feed.changes.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(covariant BeatSplit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player && _acquired) {
      _feed.release();
      _acquired = false;
    }
    _sync();
  }

  void _sync() {
    if (!mounted) return;
    final player = widget.player;
    final on = widget.enabled && player != null;
    if (on && !_acquired) {
      _feed.acquire(player);
      _acquired = true;
    } else if (!on && _acquired) {
      _feed.release();
      _acquired = false;
    }
    final run =
        on && player.playing && _feed.hasNativeFft && _feed.renderActive;
    if (run && _listen == null) {
      _listen = Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _onListen(),
      );
    } else if (!run && _listen != null) {
      _listen!.cancel();
      _listen = null;
      if (_ticker.isActive) _ticker.stop();
      _kick.reset();
      _snare.reset();
      _shownKick = 0;
      _shownSnare = 0;
      _setFrame(null);
      _repaint.value++;
    }
  }

  bool get _moving => _shownKick > 0 || _shownSnare > 0;

  void _onListen() {
    if (_ticker.isActive) return; // the ticker is stepping already
    _step(1); // the timer ticks once a 60 Hz frame
    if (_moving) {
      _lastTick = Duration.zero;
      _ticker.start();
      _paint();
    }
  }

  void _onFrame(Duration elapsed) {
    final frames = elapsed == Duration.zero
        ? 1.0
        : (elapsed - _lastTick).inMicroseconds / 16667.0;
    _lastTick = elapsed;
    _step(frames);
    _paint();
    if (!_moving) _ticker.stop();
  }

  void _paint() {
    final wasSplit = _frame != null;
    final splitNow = _split > 0.05 && !_calm;
    // One snapshot per hit, reused while it fades: a snapshot every frame was
    // a second full render of the window per frame. Hits closer together
    // than [_snapGap] share one, since the app has barely changed in between.
    final newHit = (_kick.hit || _snare.hit) && _sinceSnap.elapsed > _snapGap;
    if (splitNow && (!wasSplit || newHit)) {
      _setFrame(_snapshot());
      _sinceSnap.reset();
    } else if (!splitNow && wasSplit) {
      _setFrame(null);
    }
    _repaint.value++;
  }

  void _step(double frames) {
    _feed.refresh();
    final bins = _feed.targetBins;
    final kick = _kick.step((bins[0] + bins[1] + bins[2]) / 3, frames);
    final snare = _snare.step(
      (bins[8] + bins[9] + bins[10] + bins[11]) / 4,
      frames,
    );
    if (_kick.hit || _snare.hit) {
      // Mostly sideways, up to 35 degrees off, either way round, so two hits
      // in a row do not split the same way.
      final a =
          (_rng.nextDouble() * 2 - 1) * 0.6 + (_rng.nextBool() ? 0 : math.pi);
      _splitDir = Offset(math.cos(a), math.sin(a));
    }
    // Ease into a hit over a few frames instead of snapping to it.
    _shownKick += (kick - _shownKick) * (kick > _shownKick ? 0.7 : 1.0);
    if (_shownKick < 0.01) _shownKick = 0;
    _shownSnare += (snare - _shownSnare) * (snare > _shownSnare ? 0.75 : 1.0);
    if (_shownSnare < 0.01) _shownSnare = 0;
  }

  /// How far the colours split, 0..1: kicks and snares alike.
  double get _split => math.min(1.0, _shownSnare + _shownKick);

  /// The app as it was last drawn, at 40% resolution, or null if it cannot
  /// be taken right now.
  ui.Image? _snapshot() {
    final box = _boundary.currentContext?.findRenderObject();
    if (box is! RenderRepaintBoundary || !box.hasSize) return null;
    try {
      // 40% resolution: fringes are soft anyway, and it is a sixth of the
      // pixels to render and hold.
      return box.toImageSync(
        pixelRatio: MediaQuery.devicePixelRatioOf(context) * 0.4,
      );
    } catch (_) {
      // Debug builds refuse a boundary that is due a repaint this frame.
      return null;
    }
  }

  static const Duration _snapGap = Duration(milliseconds: 250);
  final Stopwatch _sinceSnap = Stopwatch()..start();

  void _setFrame(ui.Image? next) {
    final old = _frame;
    _frame = next;
    // Freed after the next frame, once the painter has been rebuilt without
    // it; every caller bumps [_repaint] so that rebuild happens.
    if (old != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  @override
  void dispose() {
    _listen?.cancel();
    _ticker.dispose();
    _feed.changes.removeListener(_sync);
    if (_acquired) _feed.release();
    _frame?.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // People who turned animations off in the system get no split.
    _calm = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final app = RepaintBoundary(key: _boundary, child: widget.child);
    return ValueListenableBuilder<int>(
      valueListenable: _repaint,
      child: app,
      builder: (context, _, app) {
        final split = _calm ? 0.0 : _split;
        // Sized by the app; the split copy is laid exactly over it.
        return Stack(
          alignment: Alignment.topLeft,
          children: [
            app!,
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _SplitPainter(
                    _frame,
                    _splitDir * (split * _maxSplitPx),
                    split * _maxRadial,
                    split,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Adds a red copy of the snapshot shifted one way and a blue copy the other
/// over the app, screen-blended, so edges and text grow colour fringes.
///
/// The app itself is never replaced: on Windows a snapshot taken just after a
/// resize can come back painted only up to the old width, and drawing that in
/// place of the app showed black. As fringes, a bad snapshot only means fewer
/// fringes for a moment.
class _SplitPainter extends CustomPainter {
  _SplitPainter(this.frame, this.shift, this.radial, this.strength);

  final ui.Image? frame;

  /// Where red goes; blue goes the opposite way.
  final Offset shift;

  /// How much bigger red is drawn, and blue smaller, around the middle.
  final double radial;

  /// 0..1, how bright the fringes are.
  final double strength;

  static ColorFilter _keep(int channel) => ColorFilter.matrix([
    for (var row = 0; row < 3; row++)
      for (var col = 0; col < 5; col++)
        row == channel && col == channel ? 1.0 : 0.0,
    0,
    0,
    0,
    1,
    0,
  ]);

  static final ColorFilter _red = _keep(0);
  static final ColorFilter _blue = _keep(2);

  @override
  void paint(Canvas canvas, Size size) {
    final img = frame;
    if (img == null || strength <= 0 || size.width <= 0) return;
    final scale = size.width / img.width;
    final s = shift / scale;
    final c = Offset(img.width / 2, img.height / 2);
    final alpha = (strength.clamp(0.0, 1.0) * 255).round();
    void channel(ColorFilter filter, Offset at, double zoom) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.scale(zoom);
      canvas.translate(-c.dx, -c.dy);
      canvas.drawImage(
        img,
        at,
        Paint()
          ..colorFilter = filter
          ..blendMode = BlendMode.screen
          ..filterQuality = FilterQuality.low
          ..color = Color.fromARGB(alpha, 0, 0, 0),
      );
      canvas.restore();
    }

    canvas.save();
    canvas.scale(scale);
    channel(_red, -s, 1 + radial);
    channel(_blue, s, 1 - radial);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SplitPainter old) =>
      old.frame != frame ||
      old.shift != shift ||
      old.radial != radial ||
      old.strength != strength;
}
