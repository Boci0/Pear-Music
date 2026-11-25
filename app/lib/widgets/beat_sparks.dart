import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/player_service.dart';
import '../services/visualizer_feed.dart';

/// Turns a band into a 0..1 hit level: a hit louder than the recent average
/// jumps the level up, then it falls away smoothly, so a steady bass line
/// does not keep setting off sparks.
class BeatEnvelope {
  BeatEnvelope({this.gain = 2.5, this.decay = 0.88});

  /// How strongly a hit above the average counts. Low enough that a soft kick
  /// gives a small burst and only a hard one reaches the top.
  final double gain;

  /// What is left of the level after one 60 Hz frame.
  final double decay;

  double _avg = 0;
  bool _primed = false;
  double level = 0;

  /// True when the last [step] started a new hit rather than decaying one.
  bool hit = false;

  /// [bass] is 0..1; [frames] is how many 60 Hz frames passed since the last step.
  double step(double bass, double frames) {
    final f = frames.clamp(0.0, 4.0);
    if (!_primed) {
      // Seeded from the first sample, or resuming would look like a huge hit.
      _primed = true;
      _avg = bass;
    }
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
    _primed = false;
    level = 0;
    hit = false;
  }
}

class _Spark {
  _Spark(math.Random rng, double strength)
    : x = 0.04 + rng.nextDouble() * 0.92,
      // Slow on purpose: small stars moving fast look steppy on a 60 Hz screen.
      life = 6.5 + rng.nextDouble() * 3 - strength,
      radius = 1.2 + rng.nextDouble() * 1.4 + strength,
      phase = rng.nextDouble() * math.pi * 2,
      bright = 0.55 + 0.45 * strength;

  /// Across the window, 0..1.
  final double x;

  /// Seconds to fall from the top of the window to the bottom at the base
  /// speed, so every window size gets the same fall. Beats speed it up.
  final double life;
  final double radius;

  /// Where its sideways wobble starts.
  final double phase;

  /// 0..1, harder hits make brighter sparks.
  final double bright;
  double age = 0;

  /// How far down the window it has fallen, 0..1.
  double fallen = 0;
}

/// A layer between the background and the app: on kicks and snares a few
/// small sparks in the song's accent colour, four-pointed stars, fall from the
/// top of the window to the bottom. Cards, bars, menus and sheets are drawn
/// over them, so they only show where the background does.
///
/// It replaced a red/blue colour split that snapshotted the app on every hit
/// and used a screen blend; on Impeller that cost about 30 MB of GPU memory on
/// a phone. This draws a few dozen small stars at most with a plain additive
/// blend, and only while sparks are in the air. While off, paused or parked it
/// runs no ticker.
class BeatSparks extends StatefulWidget {
  const BeatSparks({super.key, required this.enabled, required this.player});

  final bool enabled;
  final PlayerService? player;

  @override
  State<BeatSparks> createState() => _BeatSparksState();
}

class _BeatSparksState extends State<BeatSparks>
    with SingleTickerProviderStateMixin {
  final VisualizerFeed _feed = VisualizerFeed.instance;
  final BeatEnvelope _kick = BeatEnvelope();
  // Snares and claps sit in the low mids. Faster to fade than a kick.
  final BeatEnvelope _snare = BeatEnvelope(gain: 3, decay: 0.84);
  // Any sudden rise across the whole spectrum: claps, vocals, high kicks, and
  // the only listener that works on outputs with no deep bass.
  final BeatEnvelope _flux = BeatEnvelope(gain: 11, decay: 0.86);
  final List<double> _prevBins = List<double>.filled(
    VisualizerFeed.barCount,
    0,
  );
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  final math.Random _rng = math.Random();
  final List<_Spark> _sparks = [];
  // Between beats a plain timer listens, which draws nothing. The frame ticker
  // runs only while sparks are in the air: on Windows every ticker frame
  // redraws the whole window, so a ticker running through the whole song cost
  // a full redraw 60 times a second for nothing.
  late final Ticker _ticker = createTicker(_onFrame);
  Timer? _listen;
  Duration _lastTick = Duration.zero;
  bool _acquired = false;
  bool _calm = false;

  // Hits closer together than this share one burst, so a busy passage does
  // not fill the screen.
  static const double _burstGapFrames = 18; // about 300 ms
  double _framesSinceBurst = _burstGapFrames;
  static const int _maxSparks = 50;
  double _surge = 0;
  double _shownSurge = 0;

  /// For tests: how many sparks are in the air.
  @visibleForTesting
  int get debugSparkCount => _sparks.length;

  @override
  void initState() {
    super.initState();
    _feed.changes.addListener(_sync);
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // People who turned animations off in the system get no sparks.
    _calm = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(covariant BeatSparks oldWidget) {
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
    final on = widget.enabled && player != null && !_calm;
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
      _flux.reset();
      _prevBins.fillRange(0, _prevBins.length, 0);
      _sparks.clear();
      _surge = 0;
      _shownSurge = 0;
      _repaint.value++;
    }
  }

  void _onListen() {
    if (_ticker.isActive) return; // the ticker is stepping already
    _step(1); // the timer ticks once a 60 Hz frame
    if (_sparks.isNotEmpty) {
      _lastTick = Duration.zero;
      _ticker.start();
      _repaint.value++;
    }
  }

  void _onFrame(Duration elapsed) {
    final frames = elapsed == Duration.zero
        ? 1.0
        : (elapsed - _lastTick).inMicroseconds / 16667.0;
    _lastTick = elapsed;
    _step(frames);
    final dt = frames.clamp(0.0, 4.0) / 60;
    // Slow drift between beats, a surge on each one: fast, slow, fast.
    final pace = 0.55 + 2.2 * _shownSurge;
    for (final s in _sparks) {
      s.age += dt;
      s.fallen += dt / s.life * pace;
    }
    _sparks.removeWhere((s) => s.fallen >= 1);
    _repaint.value++;
    if (_sparks.isEmpty) _ticker.stop();
  }

  void _step(double frames) {
    _feed.refresh();
    final bins = _feed.targetBins;
    final kick = _kick.step((bins[0] + bins[1] + bins[2]) / 3, frames);
    final snare = _snare.step(
      (bins[8] + bins[9] + bins[10] + bins[11]) / 4,
      frames,
    );
    var rise = 0.0;
    for (var i = 0; i < _prevBins.length; i++) {
      rise += math.max(0.0, bins[i] - _prevBins[i]);
      _prevBins[i] = bins[i];
    }
    final flux = _flux.step(rise / VisualizerFeed.barCount, frames);
    _framesSinceBurst += frames;
    final hit = _kick.hit || _snare.hit || _flux.hit;
    final strength = math.min(1.0, math.max(kick + snare, flux));
    // The surge follows each hit and dies away over about half a second;
    // the shown one eases into it over a few frames so a hit never jerks.
    _surge = math.max(_surge * math.pow(0.93, frames), strength);
    _shownSurge += (_surge - _shownSurge) * (1 - math.pow(0.55, frames));
    if (hit && strength > 0.15 && _framesSinceBurst >= _burstGapFrames) {
      _framesSinceBurst = 0;
      final count = math.min(
        1 + (strength * 2).round(),
        _maxSparks - _sparks.length,
      );
      for (var i = 0; i < count; i++) {
        _sparks.add(_Spark(_rng, strength));
      }
    }
  }

  @override
  void dispose() {
    _listen?.cancel();
    _ticker.dispose();
    _feed.changes.removeListener(_sync);
    if (_acquired) _feed.release();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _SparksPainter(color, _sparks, () => _shownSurge, _repaint),
        ),
      ),
    );
  }
}

/// Each spark is a small four-pointed star in a faint halo, added over the
/// background.
class _SparksPainter extends CustomPainter {
  _SparksPainter(this.color, this.sparks, this.surge, Listenable repaint)
    : super(repaint: repaint);

  final Color color;
  final List<_Spark> sparks;

  /// 0..1, how hard the fall is surging right now.
  final double Function() surge;

  @override
  void paint(Canvas canvas, Size size) {
    if (sparks.isEmpty || size.isEmpty) return;
    final core = Color.lerp(color, Colors.white, 0.55)!;
    // Plus is a plain blend on every renderer; screen and friends make
    // Impeller render the frame off screen.
    final paint = Paint()..blendMode = BlendMode.plus;
    for (final s in sparks) {
      final t = s.fallen;
      // Fades in over a fifth of a second, holds, and fades away on the
      // lower part of the fall.
      final a = math.min(1.0, s.age / 0.2) * (1 - math.pow(t, 2.5)) * s.bright;
      // From just above the top edge to just below the bottom one.
      final p = Offset(
        s.x * size.width + math.sin(s.phase + s.age * 0.9) * 10,
        -12 + (size.height + 24) * t,
      );
      // While the beat pushes them, a short streak trails above each star:
      // one gradient line, and none at all between beats.
      final trail = size.height * 0.07 * surge();
      if (trail > 2) {
        final tail = p.translate(0, -trail);
        canvas.drawLine(
          tail,
          p,
          Paint()
            ..blendMode = BlendMode.plus
            ..strokeWidth = s.radius * 1.1
            ..strokeCap = StrokeCap.round
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                color.withValues(alpha: 0),
                core.withValues(alpha: 0.5 * a),
              ],
            ).createShader(Rect.fromPoints(tail, p)),
        );
      }
      canvas.drawCircle(
        p,
        s.radius * 3.2,
        paint..color = color.withValues(alpha: 0.14 * a),
      );
      // A slow turn and a twinkle in size, so it reads as a sparkle.
      final twinkle = 1 + 0.08 * math.sin(s.phase * 3 + s.age * 3);
      canvas
        ..save()
        ..translate(p.dx, p.dy)
        ..rotate(math.sin(s.phase + s.age * 0.7) * 0.25)
        ..scale(s.radius * 2.8 * twinkle)
        ..drawPath(_star, paint..color = core.withValues(alpha: 0.9 * a))
        ..restore();
    }
  }

  /// A four-pointed star with curved-in sides, radius 1 around the origin.
  static final Path _star = () {
    const c = 0.1; // how close the curves pull in to the middle
    return Path()
      ..moveTo(0, -1)
      ..quadraticBezierTo(c, -c, 1, 0)
      ..quadraticBezierTo(c, c, 0, 1)
      ..quadraticBezierTo(-c, c, -1, 0)
      ..quadraticBezierTo(-c, -c, 0, -1)
      ..close();
  }();

  @override
  bool shouldRepaint(covariant _SparksPainter old) => old.color != color;
}
