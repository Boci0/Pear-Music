import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../services/ambient_ticker.dart';
import '../../services/player_service.dart';
import '../../services/visualizer_feed.dart';
import 'visualizer_permission.dart';

/// An audio-reactive "butterfly" spectrum visualizer taking the full space of the album artwork.
/// Bars are mirrored around the centre: the bass bulges from the middle and the
/// treble flutters on both outer edges, so the spectrum always looks balanced
/// (no more left-heavy bias). Physics are time-based (frame-rate independent)
/// with a snappy rise, altitude gravity, a soft ceiling and ghost peak trails.
/// Native FFT on Windows/Android, harmonic modeling fallback.
class ArtworkVisualizer extends StatefulWidget {
  final PlayerService player;
  final Color accentColor;

  /// Draws dark bars on a light wash, for bright covers where light bars
  /// disappear into the artwork (the same call the lyrics make for dark text).
  final bool onBrightArt;

  const ArtworkVisualizer({
    super.key,
    required this.player,
    required this.accentColor,
    this.onBrightArt = false,
  });

  /// Test seam: forces the phone (timer) or the desktop (ticker) driver.
  @visibleForTesting
  static bool? debugPhoneRate;

  /// The tallest bar, as a share of the card's height.
  static const double maxBarFraction = 0.38;

  /// Gap between the bars and the card's bottom edge.
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

  /// Phones update the bars on the player's shared 30 Hz [AmbientTicker]
  /// instead of a vsync ticker. A ticker wakes the UI thread and re-draws the
  /// whole player scene (blurred artwork, glow) at the display's rate, which
  /// was about 80% of a core on a test phone. It has to be that shared clock,
  /// not a timer of its own: two unaligned 30 Hz timers are still two frames
  /// per 33 ms, so the glows and the bars share ticks and their frames
  /// coalesce. Desktop keeps the ticker, where the extra frames are cheap.
  bool _ambientAttached = false;

  bool get _timerDriven =>
      ArtworkVisualizer.debugPhoneRate ??
      (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  bool get _driverRunning =>
      _timerDriven ? _ambientAttached : _tickerController.isAnimating;

  void _onAmbientTick(Duration _) => _onTick();

  void _startDriver() {
    if (_timerDriven) {
      if (!_ambientAttached) {
        _ambientAttached = true;
        AmbientTicker.instance.addListener(_onAmbientTick);
      }
    } else {
      _tickerController.repeat();
    }
  }

  void _stopDriver() {
    if (_ambientAttached) {
      _ambientAttached = false;
      AmbientTicker.instance.removeListener(_onAmbientTick);
    }
    _tickerController.stop();
  }

  /// How many "60 fps frames" one step may cover: a 30 Hz step is two.
  double get _maxFrames => _timerDriven ? 3.0 : 1.0;

  /// For tests: how far the bars have grown in, 0..1.
  @visibleForTesting
  double get debugActivity => _physics.activity;

  /// Repaint gate: the canvas repaints on every tick, so the bars move at the
  /// display's refresh rate instead of a stepped 30 fps. Repaints stay cheap
  /// because the painter shares one gradient shader across all bars per frame,
  /// and the whole ticker parks whenever the window is unfocused or paused.
  final ValueNotifier<int> _paintTick = ValueNotifier<int>(0);

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
  }

  @override
  void didUpdateWidget(covariant ArtworkVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _feed.release();
      _feed.acquire(widget.player);
      _syncTicker();
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
      maxFrames: _maxFrames,
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
          // spectrum repaint never rebuilds the vignette gradient.
          RepaintBoundary(
            child: CustomPaint(
              painter: _VignettePainter(
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

    // Mirrored "butterfly" spectrum bars across the full card width
    const int totalBars = 24;
    const double spacing = 4.0;
    const double horizontalPadding = 16.0;
    final availableWidth = size.width - (horizontalPadding * 2.0);
    final barWidth = ((availableWidth - (spacing * (totalBars - 1))) / totalBars).clamp(3.0, 9.5);
    final totalSpan = (totalBars * barWidth) + (spacing * (totalBars - 1));
    final startX = (size.width - totalSpan) / 2.0;

    const double bottomPadding = ArtworkVisualizer.bottomPadding;
    final maxBarHeight = size.height * ArtworkVisualizer.maxBarFraction;
    const double minBarHeight = 4.0;

    final radius = Radius.circular(barWidth / 2.0);
    // Translucent at the base so the artwork shows through, brighter at the
    // tip: the bars read as light on the art, not solid blocks over it.
    //
    // On a bright cover that light-on-light all but vanishes, so the bars turn
    // into a deep shade of the accent instead, darkest (and most opaque) at
    // the tip where they stand against the most artwork.
    final ink = _deepInk(accentColor);
    final barBottomColor = onBrightArt
        ? Color.lerp(accentColor, ink, 0.55)!.withValues(alpha: 0.55 + (0.25 * act))
        : accentColor.withValues(alpha: 0.55 + (0.25 * act));
    final barTopColor = onBrightArt
        ? ink.withValues(alpha: 0.92)
        : Color.lerp(accentColor, Colors.white, 0.55)!.withValues(alpha: 0.95);

    // A thin halo of the opposite tone under every bar. Which polarity a cover
    // wants is guessed from its middle (the lyrics need that), but the bars
    // sit along the bottom edge, where a cover can be far brighter or darker
    // than its middle; the halo keeps them readable whichever way it falls.
    final haloPaint = Paint()
      ..color = (onBrightArt ? Colors.white : Colors.black)
          .withValues(alpha: (onBrightArt ? 0.30 : 0.24) * act);

    // One shader per frame for the whole bar band instead of one per bar:
    // every bar is anchored at the band's bottom, so a shared vertical
    // gradient still runs from the accent base up to the white tip, and tall
    // bars reach further into the light. This drops ~48 createShader calls per
    // frame down to two, which is what makes full-rate repaints affordable.
    final bandRect = Rect.fromLTWH(
      0,
      size.height - bottomPadding - maxBarHeight,
      size.width,
      maxBarHeight,
    );
    final barGradient = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [barBottomColor, barTopColor],
    );
    final trailGradient = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: onBrightArt
          ? [
              Color.lerp(accentColor, ink, 0.45)!.withValues(alpha: 0.25 * act),
              ink.withValues(alpha: 0.40 * act),
            ]
          : [
              Color.lerp(accentColor, Colors.white, 0.45)!.withValues(alpha: 0.35 * act),
              Colors.white.withValues(alpha: 0.55 * act),
            ],
    );

    // Two reusable paints, each with a shared shader, for all bars per frame.
    final trailPaint = Paint()..shader = trailGradient.createShader(bandRect);
    final barPaint = Paint()..shader = barGradient.createShader(bandRect);

    for (int i = 0; i < totalBars; i++) {
      double amp = 0.0;
      double trailAmp = 0.0;

      if (i < liveBins.length) {
        amp = liveBins[i].clamp(0.0, 1.0);
        trailAmp = (i < trailBins.length ? trailBins[i] : amp).clamp(0.0, 1.0);
      }

      final barX = startX + i * (barWidth + spacing);

      // Trailing buffer ghost bar (lighter tint, slow descent). Skip ghosts
      // that barely peek above the live bar; they only cost a draw.
      if (trailAmp > amp) {
        final trailH = minBarHeight + (maxBarHeight - minBarHeight) * trailAmp * act;
        if (trailH > minBarHeight + 2.0) {
          final trailY = size.height - bottomPadding - trailH;
          final trailRect = RRect.fromRectAndRadius(
            Rect.fromLTWH(barX, trailY, barWidth, trailH),
            radius,
          );
          canvas.drawRRect(trailRect, trailPaint);
        }
      }

      // Foreground active bar
      final barH = minBarHeight + (maxBarHeight - minBarHeight) * amp * act;
      final barY = size.height - bottomPadding - barH;

      final barRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(barX, barY, barWidth, barH),
        radius,
      );

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          barRect.outerRect.inflate(_haloPad),
          Radius.circular(barWidth / 2.0 + _haloPad),
        ),
        haloPaint,
      );
      canvas.drawRRect(barRect, barPaint);
    }
  }

  /// How far the halo reaches past a bar's edge.
  static const double _haloPad = 1.0;

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
