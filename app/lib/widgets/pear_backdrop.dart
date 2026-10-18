import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../theme/glass.dart' show pearGrainAsset;
import '../theme/pear_style.dart';

/// The room behind every route: the ambient canvas colour, soft glows of the
/// current song's colours, and a faint, slanted watermark of the pear logo.
///
/// The glows are what the glass panels (see `PearGlass`) frost over, so the
/// chrome picks up the music's colour as it plays.
///
/// The watermark tile is built once per display scale from
/// `assets/pear_logo.png`. The outline is the logo's silhouette minus an
/// eroded copy of itself, so the line keeps one width along the pear's
/// contour (stem and leaf included). The tile is then tiled with an
/// [ui.ImageShader], so
/// the whole backdrop costs one rectangle draw per frame and lives behind
/// everything via `MaterialApp.builder`.
///
/// Screens keep a transparent Scaffold background (see [PlayerTheme]) so
/// this shows through; opaque chrome (rail, pane card, strips) stays calm on
/// top of it.
class PearBackdrop extends StatefulWidget {
  const PearBackdrop({super.key});

  /// Renders one watermark tile at [dpr] device pixels per logical pixel.
  @visibleForTesting
  static Future<ui.Image> renderTile(double dpr) =>
      _PearBackdropState._render(dpr);

  /// Test seam: forces the one-image draw on or off (on by default on
  /// phones only).
  @visibleForTesting
  static bool? debugBake;

  @override
  State<PearBackdrop> createState() => _PearBackdropState();
}

class _PearBackdropState extends State<PearBackdrop> {
  /// Tile size in logical px. The pear sits centred with wide margins so
  /// neighbouring marks stay clearly apart.
  static const double _tile = 150;

  /// Pear mark size in logical px.
  static const double _mark = 62;

  /// Outline width in logical px. The silhouette is eroded by this much and
  /// cut out of itself, so the line is the same width all the way round.
  static const double _stroke = 3.5;

  /// Wallpaper slant, in degrees.
  static const double _slantDegrees = -18;

  /// Tiles shared by every backdrop (the app-wide one plus the copy each page
  /// transition brings), one per device pixel ratio seen, so moving a window
  /// between displays and back reuses them. They are never disposed: another
  /// backdrop or an in-flight frame may still be drawing one, and there are
  /// only ever as many as there are display scales.
  static final Map<double, ui.Image> _sharedTiles = {};

  /// The grain tile, decoded once for every backdrop.
  static ui.Image? _sharedGrain;

  ui.Image? _tileImage;
  ui.Image? _grain;

  /// Snap a colour to the bake key's resolution. MaterialApp lerps the whole
  /// ThemeData over 200 ms when the song changes the palette, so a bake key
  /// holding the raw colours would rebuild a window-sized image on about
  /// twelve of those frames, which costs more than the bake saves. Sixteen
  /// steps per channel is far below what a soft glow can show, and it leaves
  /// one or two rebakes for a whole transition.
  static int _snap(Color? color) =>
      color == null ? 0 : ((color.toARGB32() >> 4) & 0x0F0F0F0F);

  /// Device pixel ratio [_tileImage] was rendered at, so the painter can draw
  /// it back at its logical size.
  double _tileDpr = 1;

  int _generation = 0;

  /// The finished backdrop as one image. Every backend that redraws the scene
  /// when anything on it animates pays for the five full-screen passes the
  /// backdrop is made of (canvas, three glows, watermark) on every presented
  /// frame, and the player animates for as long as a song plays. Measured at
  /// about 5 CPU points at 60 frames a second on a phone; on the Windows
  /// build the same passes were being paid for across a 1252x922 window,
  /// about 5.8 megapixels of fill per frame. Baked, the whole backdrop is one
  /// textured rectangle.
  final _BackdropBake _bake = _BackdropBake();

  bool get _bakes => PearBackdrop.debugBake ?? !kIsWeb;

  @override
  void initState() {
    super.initState();
    _grain = _sharedGrain;
    if (_grain == null) _loadGrain();
  }

  Future<void> _loadGrain() async {
    final data = await rootBundle.load(pearGrainAsset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    _sharedGrain ??= image;
    if (!mounted) return;
    setState(() => _grain = _sharedGrain);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    if (_tileImage != null && _tileDpr == dpr) return;
    final shared = _sharedTiles[dpr];
    if (shared != null) {
      _generation++;
      _tileImage = shared;
      _tileDpr = dpr;
    } else {
      // The old tile keeps painting (at its own ratio, so at the right size)
      // until the sharper one is ready.
      _renderTile(dpr);
    }
  }

  @override
  void dispose() {
    _generation++;
    _bake.dispose();
    super.dispose();
  }

  Future<void> _renderTile(double dpr) async {
    final generation = ++_generation;
    final image = await _render(dpr);

    // Keep the result even if this backdrop has gone away meanwhile: the
    // next one reuses it.
    _sharedTiles[dpr] = image;
    if (!mounted || generation != _generation) return;
    setState(() {
      _tileImage = image;
      _tileDpr = dpr;
    });
  }

  static Future<ui.Image> _render(double dpr) async {
    final data = await rootBundle.load('assets/pear_logo.png');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    codec.dispose();
    final logo = frame.image;

    final tilePx = (_tile * dpr).round();
    final markPx = _mark * dpr;
    final tileRect = Rect.fromLTWH(0, 0, tilePx.toDouble(), tilePx.toDouble());
    final src =
        Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble());
    final dst = Rect.fromCenter(
      center: tileRect.center,
      width: markPx,
      height: markPx,
    );
    final stroke = _stroke * dpr;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.saveLayer(tileRect, Paint());
    canvas.drawImageRect(
      logo,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = const ColorFilter.mode(Colors.white, BlendMode.srcIn),
    );
    // Cut out the silhouette shrunk by the stroke width, leaving an even
    // outline that follows the contour (stem and leaf included).
    canvas.saveLayer(
      tileRect,
      Paint()
        ..blendMode = BlendMode.dstOut
        ..imageFilter = ui.ImageFilter.erode(radiusX: stroke, radiusY: stroke),
    );
    canvas.drawImageRect(
      logo,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
    canvas.restore();

    final picture = recorder.endRecording();
    final image = await picture.toImage(tilePx, tilePx);
    picture.dispose();
    logo.dispose();
    return image;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      // The glows and the watermark follow the chosen style.
      child: ValueListenableBuilder<PearStyle>(
        valueListenable: PearStyles.current,
        builder: (context, style, _) => CustomPaint(
          painter: _BackdropPainter(
            scheme: scheme,
            tile: _tileImage,
            tileDpr: _tileDpr,
            grain: _grain,
            grainAlpha: PearStyles.spec.grainAlpha,
            bake: _bakes ? _bake : null,
            glowScale: PearStyles.spec.glowScale,
            watermarkAlpha: PearStyles.spec.watermarkAlpha,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// Holds the backdrop drawn once into an image, redrawn only when its
/// inputs (size, colours, watermark tile, pixel ratio) change.
class _BackdropBake {
  ui.Image? _image;
  Object? _key;

  ui.Image get(Size size, double ratio, Object key, void Function(Canvas) draw) {
    final image = _image;
    if (image != null && _key == key) return image;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);
    draw(canvas);
    final picture = recorder.endRecording();
    final baked = picture.toImageSync(
      (size.width * ratio).ceil(),
      (size.height * ratio).ceil(),
    );
    picture.dispose();
    // A frame already recorded keeps its own reference to the old image.
    image?.dispose();
    _key = key;
    return _image = baked;
  }

  void dispose() {
    _image?.dispose();
    _image = null;
  }
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter({
    required this.scheme,
    required this.tile,
    required this.tileDpr,
    required this.grain,
    required this.grainAlpha,
    required this.glowScale,
    required this.watermarkAlpha,
    this.bake,
  });

  final _BackdropBake? bake;

  /// Multiplier on the glows' strength and the watermark's alpha, from the
  /// current style.
  final double glowScale;
  final double watermarkAlpha;

  final ColorScheme scheme;
  final ui.Image? tile;

  /// Fine noise drawn over the glows, at one grain pixel per screen pixel.
  final ui.Image? grain;
  final double grainAlpha;

  /// Device pixels per logical pixel in [tile]. The canvas is in logical
  /// pixels, so the shader scales the tile down by this to keep the mark at
  /// its designed size on scaled displays.
  final double tileDpr;

  /// Soft colour glows: where they sit (as a fraction of the window), how far
  /// they reach (as a fraction of the longer side) and how strong they are.
  static const _glows = [
    (x: 0.08, y: -0.08, reach: 0.75, alpha: 0.52),
    (x: 1.00, y: 0.30, reach: 0.60, alpha: 0.36),
    (x: 0.35, y: 1.10, reach: 0.70, alpha: 0.42),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final bake = this.bake;
    if (bake == null || size.isEmpty) {
      _draw(canvas, size);
      return;
    }
    final image = bake.get(
      size,
      tileDpr,
      (
        size,
        _PearBackdropState._snap(scheme.surface),
        _PearBackdropState._snap(scheme.primary),
        _PearBackdropState._snap(scheme.secondary),
        _PearBackdropState._snap(scheme.tertiary),
        tile,
        tileDpr,
        glowScale,
        watermarkAlpha,
        grain,
        grainAlpha,
      ),
      (c) => _draw(c, size),
    );
    canvas
      ..save()
      ..scale(1 / tileDpr)
      ..drawImage(image, Offset.zero, Paint())
      ..restore();
  }

  void _draw(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = scheme.surface);

    final longest = size.longestSide;
    final colors = [scheme.primary, scheme.tertiary, scheme.secondary];
    for (var i = 0; i < _glows.length; i++) {
      if (glowScale <= 0) break;
      final glow = (
        x: _glows[i].x,
        y: _glows[i].y,
        reach: _glows[i].reach,
        alpha: (_glows[i].alpha * glowScale).clamp(0.0, 0.9),
      );
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

    final noise = grain;
    if (noise != null && grainAlpha > 0) {
      canvas.drawRect(
        rect,
        Paint()
          ..filterQuality = FilterQuality.none
          ..shader = ui.ImageShader(
            noise,
            TileMode.repeated,
            TileMode.repeated,
            Matrix4.diagonal3Values(1 / tileDpr, 1 / tileDpr, 1).storage,
          )
          ..colorFilter = ColorFilter.matrix(<double>[
            1, 0, 0, 0, 0,
            0, 1, 0, 0, 0,
            0, 0, 1, 0, 0,
            0, 0, 0, grainAlpha, 0,
          ]),
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
          (Matrix4.rotationZ(_PearBackdropState._slantDegrees * math.pi / 180)
                ..scaleByDouble(1 / tileDpr, 1 / tileDpr, 1, 1))
              .storage,
        )
        ..colorFilter = ColorFilter.mode(
          Colors.white.withValues(alpha: watermarkAlpha),
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
        oldDelegate.tile != tile ||
        oldDelegate.tileDpr != tileDpr ||
        oldDelegate.grain != grain ||
        oldDelegate.grainAlpha != grainAlpha ||
        oldDelegate.glowScale != glowScale ||
        oldDelegate.watermarkAlpha != watermarkAlpha;
  }
}
