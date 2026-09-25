import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// The room behind every route: the ambient canvas colour, soft glows of the
/// current song's colours, and a faint, slanted watermark of the pear logo.
///
/// The glows are what the glass panels (see `PearGlass`) frost over, so the
/// chrome picks up the music's colour as it plays.
///
/// The watermark tile is built once from `assets/pear_logo.png`. The outline
/// is the logo's own silhouette stamped twice, outer copy minus a slightly
/// smaller inner copy, so the ring follows the pear's contour exactly (stem
/// and leaf included). The tile is then tiled with an [ui.ImageShader], so
/// the whole backdrop costs one rectangle draw per frame and lives behind
/// everything via `MaterialApp.builder`.
///
/// Screens keep a transparent Scaffold background (see [PlayerTheme]) so
/// this shows through; opaque chrome (rail, pane card, strips) stays calm on
/// top of it.
class PearBackdrop extends StatefulWidget {
  const PearBackdrop({super.key});

  @override
  State<PearBackdrop> createState() => _PearBackdropState();
}

class _PearBackdropState extends State<PearBackdrop> {
  /// Tile size in logical px. The pear sits centred with wide margins so
  /// neighbouring marks stay clearly apart.
  static const double _tile = 150;

  /// Pear mark size in logical px.
  static const double _mark = 62;

  /// Ring thickness as a fraction of the mark: the inner copy is stamped at
  /// (1 - [_ring]) so the resulting line is [_ring] / 2 of the mark wide.
  static const double _ring = 0.20;

  /// Wallpaper slant, in degrees.
  static const double _slantDegrees = -18;

  /// How loud the watermark is. Deliberately faint: it reads as texture, not
  /// decoration.
  static const double _alpha = 0.035;

  ui.Image? _tileImage;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_tileImage == null) {
      _renderTile();
    }
  }

  @override
  void dispose() {
    _generation++;
    _tileImage?.dispose();
    super.dispose();
  }

  Future<void> _renderTile() async {
    final generation = ++_generation;
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;

    final data = await rootBundle.load('assets/pear_logo.png');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    final logo = frame.image;

    final tilePx = (_tile * dpr).round();
    final markPx = _mark * dpr;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(tilePx / 2, tilePx / 2);
    final src =
        Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble());

    void stamp(double scale, Paint paint) {
      canvas.drawImageRect(
        logo,
        src,
        Rect.fromCenter(
          center: center,
          width: markPx * scale,
          height: markPx * scale,
        ),
        paint,
      );
    }

    canvas.saveLayer(
      Rect.fromLTWH(0, 0, tilePx.toDouble(), tilePx.toDouble()),
      Paint(),
    );
    stamp(
      1,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = const ColorFilter.mode(Colors.white, BlendMode.srcIn),
    );
    stamp(
      1 - _ring,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..blendMode = BlendMode.dstOut,
    );
    canvas.restore();

    final picture = recorder.endRecording();
    final image = await picture.toImage(tilePx, tilePx);
    picture.dispose();
    logo.dispose();

    if (!mounted || generation != _generation) {
      image.dispose();
      return;
    }
    // The previous tile is dropped, not disposed: an in-flight frame may
    // still be rasterising it, and one 140px image does not matter.
    setState(() {
      _tileImage = image;
    });
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _BackdropPainter(
          scheme: Theme.of(context).colorScheme,
          tile: _tileImage,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter({required this.scheme, required this.tile});

  final ColorScheme scheme;
  final ui.Image? tile;

  /// Soft colour glows: where they sit (as a fraction of the window), how far
  /// they reach (as a fraction of the longer side) and how strong they are.
  static const _glows = [
    (x: 0.08, y: -0.08, reach: 0.75, alpha: 0.34),
    (x: 1.00, y: 0.30, reach: 0.60, alpha: 0.20),
    (x: 0.35, y: 1.10, reach: 0.70, alpha: 0.24),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = scheme.surface);

    final longest = size.longestSide;
    final colors = [scheme.primary, scheme.tertiary, scheme.secondary];
    for (var i = 0; i < _glows.length; i++) {
      final glow = _glows[i];
      final color = colors[i];
      final center = Offset(size.width * glow.x, size.height * glow.y);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: glow.alpha),
              color.withValues(alpha: glow.alpha * 0.35),
              color.withValues(alpha: 0),
            ],
            stops: const [0, 0.45, 1],
          ).createShader(
            Rect.fromCircle(center: center, radius: longest * glow.reach),
          ),
      );
    }

    final image = tile;
    if (image == null) {
      return;
    }

    canvas.drawRect(
      rect,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..shader = ui.ImageShader(
          image,
          TileMode.repeated,
          TileMode.repeated,
          Matrix4.rotationZ(
            _PearBackdropState._slantDegrees * math.pi / 180,
          ).storage,
        )
        ..colorFilter = ColorFilter.mode(
          Colors.white.withValues(alpha: _PearBackdropState._alpha),
          BlendMode.srcIn,
        ),
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter oldDelegate) {
    return oldDelegate.scheme.surface != scheme.surface ||
        oldDelegate.scheme.primary != scheme.primary ||
        oldDelegate.scheme.secondary != scheme.secondary ||
        oldDelegate.scheme.tertiary != scheme.tertiary ||
        oldDelegate.tile != tile;
  }
}
