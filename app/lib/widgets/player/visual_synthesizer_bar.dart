import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/player_service.dart';
import '../../services/visualizer_feed.dart';
import 'cover_band.dart';
import 'ribbon_paths.dart';
import 'visualizer_permission.dart';

/// An audio-reactive "butterfly" spectrum visualizer along the bottom of the
/// album artwork, drawn as one soft wave with a bright crest.
/// The wave is mirrored around the centre: the bass swells in the middle and
/// the treble flutters at both ends, so the spectrum always looks balanced.
/// Physics are time-based (frame-rate independent) with a snappy rise,
/// altitude gravity, a soft ceiling and a ghost of the recent peaks behind it.
/// Native FFT on Windows/Android, harmonic modeling fallback.
class ArtworkVisualizer extends StatefulWidget {
  final PlayerService player;
  final Color accentColor;

  /// Draws dark bars on a light wash, for bright covers where light bars
  /// disappear into the artwork (the same call the lyrics make for dark text).
  final bool onBrightArt;

  /// The cover the wave sits on, the same provider the card shows so its
  /// decode is shared. A soft band of it is baked behind the wave; without
  /// one (no cover yet) the wave sits on a plain shade of the accent.
  final ImageProvider? cover;

  const ArtworkVisualizer({
    super.key,
    required this.player,
    required this.accentColor,
    this.onBrightArt = false,
    this.cover,
  });

  /// The tallest crest, as a share of the card's height.
  static const double maxBarFraction = 0.36;

  /// Gap between the wave's baseline (where its crest bottoms out) and the
  /// card's bottom edge.
  static const double bottomPadding = 12.0;

  /// Height of the band at the bottom of a [cardHeight] card the bars can
  /// reach. The lyrics keep above it while the visualizer is on.
  static double bandHeight(double cardHeight) =>
      cardHeight * maxBarFraction + bottomPadding;

  @override
  State<ArtworkVisualizer> createState() => _ArtworkVisualizerState();
}

class _ArtworkVisualizerState extends State<ArtworkVisualizer>
    with SingleTickerProviderStateMixin {
  final VisualizerFeed _feed = VisualizerFeed.instance;
  final SpectrumPhysics _physics = SpectrumPhysics();
  late final AnimationController _tickerController;

  bool get _driverRunning => _tickerController.isAnimating;

  void _startDriver() => _tickerController.repeat();

  void _stopDriver() => _tickerController.stop();

  /// For tests: how far the bars have grown in, 0..1.
  @visibleForTesting
  double get debugActivity => _physics.activity;

  /// For tests: whether the cover band is baked and behind the wave.
  @visibleForTesting
  bool get debugHasBand => _band != null;

  /// Repaint gate: the canvas repaints on every tick, so the bars move at the
  /// display's refresh rate instead of a stepped 30 fps. On a phone each
  /// presented frame costs about half a CPU point per frame a second, the
  /// whole scene's, not the wave's; the ticker parks whenever the window is
  /// unfocused or the song is paused, so nothing runs while nothing moves.
  final ValueNotifier<int> _paintTick = ValueNotifier<int>(0);

  /// The baked band behind the wave and what it is baked from, kept so a
  /// change of polarity (bright or dark cover text) re-bakes without
  /// resolving the cover again.
  ImageStream? _coverStream;
  ImageStreamListener? _coverListener;
  ImageInfo? _coverInfo;
  ui.Image? _band;

  /// Slightly under one 60 Hz frame, so a steady 60 Hz display is never
  /// skipped by timer jitter. Repainting at most about 60 times a second is
  /// enough: on 120 or 144 Hz displays repainting every tick only doubled the
  /// GPU cost. The bar state still advances every tick, so motion speed is
  /// unchanged.
  static const int _minPaintGapMs = 15;
  int _lastPaintMs = 0;

  @override
  void initState() {
    super.initState();
    // The setting keeps the visualizer on, so it is mounted with the card
    // rather than switched on while the card is showing: the bars grow in
    // from nothing (activity starts at 0) instead of appearing at full height.
    _tickerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_onTick);
    _feed.acquire(widget.player);
    _feed.changes.addListener(_onFeedChanged);
    _syncTicker();
    VisualizerPermission.askOnce(context);
    _resolveCover();
  }

  void _resolveCover() {
    final old = _coverListener;
    if (old != null) _coverStream?.removeListener(old);
    _coverStream = null;
    final provider = widget.cover;
    if (provider == null) {
      _setCover(null);
      return;
    }
    final listener = ImageStreamListener(
      (info, _) {
        if (mounted) {
          _setCover(info.clone());
        }
      },
      onError: (_, _) {
        if (mounted) _setCover(null);
      },
    );
    _coverListener = listener;
    _coverStream = provider.resolve(ImageConfiguration.empty)
      ..addListener(listener);
  }

  void _setCover(ImageInfo? info) {
    _coverInfo?.dispose();
    _coverInfo = info;
    _bake();
  }

  void _bake() {
    final info = _coverInfo;
    final band = info == null
        ? null
        : CoverBand.bake(info.image, onBrightArt: widget.onBrightArt);
    _band?.dispose();
    if (mounted) {
      setState(() => _band = band);
    } else {
      _band = band;
    }
  }

  @override
  void didUpdateWidget(covariant ArtworkVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _feed.release();
      _feed.acquire(widget.player);
      _syncTicker();
    }
    if (oldWidget.cover != widget.cover) {
      _resolveCover();
    } else if (oldWidget.onBrightArt != widget.onBrightArt &&
        _coverInfo != null) {
      _bake();
    }
  }

  void _onFeedChanged() {
    _syncTicker();
    if (mounted) setState(() {});
  }

  void _syncTicker() {
    if ((widget.player.playing || _physics.activity > 0.0) && _feed.renderActive) {
      if (!_driverRunning) {
        _physics.resetClock();
        _startDriver();
      }
    } else if (_physics.activity <= 0.0 && _driverRunning) {
      _stopDriver();
      _requestPaint();
    }
  }

  void _onTick() {
    if (!mounted) return;
    final playing = widget.player.playing && _feed.renderActive;
    _feed.refresh();
    final settled = _physics.step(
      playing: playing,
      targets: _feed.targetBins,
    );
    if (settled) {
      // Stop the driver whenever rendering is inactive (paused, backgrounded
      // or unfocused), not only when playback itself stopped.
      _stopDriver();
      _requestPaint();
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastPaintMs >= _minPaintGapMs) {
      _lastPaintMs = nowMs;
      _requestPaint();
    }
  }

  void _requestPaint() {
    _paintTick.value++;
  }

  @override
  void dispose() {
    final listener = _coverListener;
    if (listener != null) _coverStream?.removeListener(listener);
    _coverInfo?.dispose();
    _band?.dispose();
    _stopDriver();
    _feed.changes.removeListener(_onFeedChanged);
    _feed.release();
    _paintTick.dispose();
    _tickerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Static backdrop layer: rendered once and cached, so the per-frame
          // spectrum repaint never rebuilds it.
          RepaintBoundary(
            child: CustomPaint(
              painter: _band != null
                  ? _BandPainter(_band!)
                  : _VignettePainter(
                      widget.accentColor,
                      onBrightArt: widget.onBrightArt,
                    ),
            ),
          ),
          // No AnimatedBuilder here: repaints are driven by [_paintTick]
          // through the painter's repaint listenable, so the widget tree is
          // not rebuilt on every frame.
          CustomPaint(
            size: Size.infinite,
            willChange: true,
            painter: _ArtworkVisualizerPainter(
              accentColor: widget.accentColor,
              onBrightArt: widget.onBrightArt,
              activity: () => _physics.activity,
              liveBins: _physics.display,
              trailBins: _physics.trail,
              repaint: _paintTick,
            ),
          ),
        ],
      ),
    );
  }
}

/// Static backdrop for the visualizer, kept behind its own RepaintBoundary
/// layer so it is drawn once instead of on every animation frame.
///
/// A deep shade of the song's accent rather than black: it seats the bars in
/// the artwork's own colour instead of laying a flat dark filter over it. On
/// a bright cover it is a pale wash instead, behind the dark bars.
class _VignettePainter extends CustomPainter {
  const _VignettePainter(this.accentColor, {this.onBrightArt = false});

  final Color accentColor;
  final bool onBrightArt;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final shade = onBrightArt
        ? Color.lerp(accentColor, Colors.white, 0.85)!
        : Color.lerp(accentColor, Colors.black, 0.72)!;
    final vignetteRect = Rect.fromLTWH(0, size.height * 0.55, size.width, size.height * 0.45);
    final vignettePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          shade.withValues(alpha: 0.46),
          shade.withValues(alpha: 0.14),
          shade.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(vignetteRect);
    canvas.drawRect(vignetteRect, vignettePaint);
  }

  @override
  bool shouldRepaint(covariant _VignettePainter oldDelegate) =>
      oldDelegate.accentColor != accentColor ||
      oldDelegate.onBrightArt != onBrightArt;
}

/// Draws the baked [CoverBand] over the bottom of the card.
class _BandPainter extends CustomPainter {
  const _BandPainter(this.band);

  final ui.Image band;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final top = size.height * CoverBand.top;
    canvas.drawImageRect(
      band,
      Rect.fromLTWH(0, 0, band.width.toDouble(), band.height.toDouble()),
      Rect.fromLTRB(0, top, size.width, size.height),
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _BandPainter oldDelegate) =>
      oldDelegate.band != band;
}

class _ArtworkVisualizerPainter extends CustomPainter {
  final Color accentColor;
  final bool onBrightArt;

  /// Read at paint time because the value keeps decaying between rebuilds.
  final double Function() activity;
  final List<double> liveBins;
  final List<double> trailBins;

  _ArtworkVisualizerPainter({
    required this.accentColor,
    this.onBrightArt = false,
    required this.activity,
    required this.liveBins,
    required this.trailBins,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final act = activity();
    // Nothing playing: nothing drawn (the wave fades in and out with
    // [activity]); a flat line left over the cover read as a stray seek bar.
    if (act <= 0.003) return;

    // One soft wave across the card, mirrored about the centre so the bass
    // swells in the middle and the treble flutters at both ends. A filled
    // shape with a bright crest, and behind it a slower "ghost" of the recent
    // peaks, instead of a row of separate bars.
    final baseY = size.height - ArtworkVisualizer.bottomPadding;
    final maxH = size.height * ArtworkVisualizer.maxBarFraction;
    final bandTop = baseY - maxH;
    final fade = act;

    // Edge to edge: the card's rounded corners trim it, so it never ends in
    // a vertical side.
    final live = ribbonPoints(
      liveBins,
      width: size.width,
      baseY: baseY,
      maxHeight: maxH,
      padding: 0,
      scale: act,
    );
    final ghost = ribbonPoints(
      trailBins,
      width: size.width,
      baseY: baseY,
      maxHeight: maxH,
      padding: 0,
      scale: act,
    );
    if (live.length < 2) return;

    // Translucent at the base so the artwork shows through, brightest at the
    // crest. On a bright cover light-on-light all but vanishes, so the wave
    // turns into a deep shade of the accent with a light edge instead.
    final ink = _deepInk(accentColor);
    final light = Color.lerp(accentColor, Colors.white, 0.6)!;
    final fillTop = (onBrightArt ? ink : light).withValues(alpha: 0.30 * fade);
    final fillBottom = onBrightArt
        ? Color.lerp(accentColor, ink, 0.5)!.withValues(alpha: 0.10 * fade)
        : accentColor.withValues(alpha: 0.10 * fade);
    final ghostColor =
        (onBrightArt ? ink : light).withValues(alpha: 0.12 * fade);
    final crestColor = onBrightArt ? ink : Colors.white;
    // A thin opposite-tone edge keeps the crest readable on any cover: which
    // polarity a cover wants is guessed from its middle, but the wave sits
    // along the bottom, where it can be brighter or darker than that.
    final edgeColor = (onBrightArt ? Colors.white : Colors.black)
        .withValues(alpha: (onBrightArt ? 0.30 : 0.14) * fade);

    // The fill runs down to the card's bottom edge so the wave sits in the
    // cover rather than on a stripe of bare art; the crest keeps its floor.
    canvas.drawPath(
      ribbonCurve(ghost, closeAtY: size.height),
      Paint()..color = ghostColor,
    );
    canvas.drawPath(
      ribbonCurve(live, closeAtY: size.height),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [fillTop, fillBottom],
        ).createShader(
          Rect.fromLTRB(0, bandTop, size.width, size.height),
        ),
    );
    final crest = ribbonCurve(live);
    canvas.drawPath(
      crest,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.4
        ..strokeJoin = StrokeJoin.round
        ..color = edgeColor,
    );
    canvas.drawPath(
      crest,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeJoin = StrokeJoin.round
        // Quieter at the peaks, firmer where the wave is low, so the crest
        // reads as the edge of the fill rather than a wire laid over it.
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            crestColor.withValues(alpha: 0.55 * fade),
            crestColor.withValues(alpha: 0.85 * fade),
          ],
        ).createShader(Rect.fromLTRB(0, bandTop, size.width, baseY)),
    );
  }

  /// A very dark shade of [accent] when it has real colour, otherwise a
  /// near-black: a pale or grey accent only darkened a little stays close to
  /// the bright cover it sits on.
  static Color _deepInk(Color accent) {
    final hsl = HSLColor.fromColor(accent);
    if (hsl.saturation < 0.3) return const Color(0xFF141416);
    return hsl
        .withLightness(0.18)
        .withSaturation(hsl.saturation.clamp(0.0, 0.7))
        .toColor();
  }

  @override
  bool shouldRepaint(covariant _ArtworkVisualizerPainter oldDelegate) {
    return oldDelegate.accentColor != accentColor ||
        oldDelegate.onBrightArt != onBrightArt;
  }
}

/// Legacy progress-bar visualizer kept for compatibility.
class VisualSynthesizerBar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
