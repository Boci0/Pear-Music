import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Photo-style colour presets for the whole-app filter, in Settings order.
abstract final class ColorGrade {
  static const int off = 0;
  static const int warm = 1;
  static const int cool = 2;
  static const int mono = 3;
  static const int sepia = 4;
  static const int faded = 5;

  static const List<String> labels = [
    'Off',
    'Warm',
    'Cool',
    'Mono',
    'Sepia',
    'Faded',
  ];

  /// The passes that make [grade]: each colour is laid over the app with its
  /// blend mode, the alpha setting how strongly. Modulate equals multiply for
  /// an opaque colour but is a plain GPU blend; multiply reads the screen back. Blending over the finished
  /// picture costs a full-screen fill; a colour-matrix filter on the whole
  /// app instead redrew it off screen every frame (measured: GPU 10% to 27%
  /// and about 200 MB more memory on the laptop).
  static List<(Color, BlendMode)> passes(int grade) => switch (grade) {
    warm => const [(Color(0xFFFFEFD6), BlendMode.modulate)],
    cool => const [(Color(0xFFDDEBFF), BlendMode.modulate)],
    mono => const [(Color(0xFF808080), BlendMode.saturation)],
    sepia => const [
      (Color(0xFF808080), BlendMode.saturation),
      (Color(0xFFFFE4BE), BlendMode.modulate),
    ],
    // Lifted blacks and a little less colour: washed film.
    faded => const [
      (Color(0x66808080), BlendMode.saturation),
      (Color(0xFF242424), BlendMode.screen),
    ],
    _ => const [],
  };
}

/// Lays the chosen colour grade and soft blur over [child], the whole app.
///
/// The colour grade is a plain overlay, cheap. The soft blur has to redraw the
/// whole window through a blur every frame, so it is the costly part and
/// sits behind its own switch. The tree keeps the same shape for every
/// setting, so switching never rebuilds the app underneath.
class ImmersionFilter extends StatelessWidget {
  const ImmersionFilter({
    super.key,
    required this.grade,
    required this.softBlur,
    required this.child,
  });

  final int grade;
  final bool softBlur;
  final Widget child;

  static const double _blurSigma = 1.4;

  // ImageFiltered needs a filter even while disabled.
  static final ui.ImageFilter _none =
      ui.ImageFilter.matrix(Matrix4.identity().storage);

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          enabled: softBlur,
          imageFilter: softBlur
              ? ui.ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma)
              : _none,
          child: child,
        ),
        IgnorePointer(
          child: CustomPaint(painter: _GradePainter(ColorGrade.passes(grade))),
        ),
      ],
    );
  }
}

class _GradePainter extends CustomPainter {
  const _GradePainter(this.passes);

  final List<(Color, BlendMode)> passes;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    for (final (color, mode) in passes) {
      canvas.drawRect(rect, Paint()
        ..color = color
        ..blendMode = mode);
    }
  }

  @override
  bool shouldRepaint(covariant _GradePainter old) => old.passes != passes;
}
