import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// The soft band of the cover the visualizer's wave sits on: the bottom part
/// of the cover, blurred, dimmed and feathered out towards its top.
///
/// Baked once per song into a tiny image, so each frame draws one textured
/// rectangle instead of a gradient over the live artwork. The wave then reads
/// against a calm version of the cover's own colours, which is also what makes
/// the lyrics-open card look settled.
class CoverBand {
  CoverBand._();

  /// The top of the band, as a share of the card's height. Matches the
  /// vignette it replaces.
  static const double top = 0.55;

  /// Width of the baked image. The band is blurred, so a small image scaled up
  /// by the sampler loses nothing and costs almost no memory.
  static const int width = 96;

  /// Blur radius in baked pixels (about 40 px on a phone-sized card).
  static const double sigma = 4;

  /// Bakes the band of [cover] (the whole cover, any size). [onBrightArt]
  /// dims with a pale wash at half strength rather than a dark one, so the
  /// dark wave drawn over a bright cover keeps its contrast.
  static ui.Image bake(ui.Image cover, {required bool onBrightArt}) {
    final w = width.toDouble();
    final h = (width * (1 - top)).roundToDouble();
    final rect = Rect.fromLTWH(0, 0, w, h);
    final srcTop = cover.height * top;
    final src = Rect.fromLTWH(
      0,
      srcTop,
      cover.width.toDouble(),
      cover.height - srcTop,
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.saveLayer(rect, Paint());
    canvas.drawImageRect(
      cover,
      src,
      rect,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.clamp,
        ),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = onBrightArt
            ? const Color(0xFFFFFFFF).withValues(alpha: 0.275)
            : const Color(0xFF000000).withValues(alpha: 0.42),
    );
    // Feather: transparent at the top so the band melts into the cover.
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00FFFFFF), Color(0xFFFFFFFF)],
          stops: [0.0, 0.6],
        ).createShader(rect),
    );
    canvas.restore();

    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, h.round());
    picture.dispose();
    return image;
  }
}
