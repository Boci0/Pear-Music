/// The soft glass material: frosted, see-through panels that let the
/// artwork-tinted backdrop glow through.
///
/// Floating chrome (side rail, nav bar, mini player, Now Playing pane, menu
/// and status strips) is built from [PearGlass] so every panel shares one
/// fill and one edge.
///
/// Only panels that content scrolls underneath (the mini player and the
/// phone nav bar) pay for a real backdrop blur; the rest sit over the static
/// backdrop, where a blur would look the same but be recomputed every time
/// the panel's own content animates. With Reduced Effects on, the blur is
/// dropped everywhere and the fill turns opaque.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/player_theme.dart';
import 'pear_style.dart';

/// Values shared by every glass surface. Most follow the current
/// [PearStyle] (see `pear_style.dart`); the shapes stay the same in all of
/// them.
class PearGlassTokens {
  PearGlassTokens._();

  /// Backdrop blur strength. High enough that list text scrolling under the
  /// mini player reads as colour, not as legible letters.
  static double get blur => PearStyles.spec.blur;

  /// Tint laid over the backdrop. Kept thin on purpose: the glass has to let
  /// the backdrop's glows through, or it reads as grey plastic instead of
  /// frosted glass.
  static double get baseAlpha => PearStyles.spec.baseAlpha;

  /// How much of the accent colour goes into the panel's base, so the body
  /// is a tinted glass rather than the canvas's own grey laid over itself.
  static double get accentTint => PearStyles.spec.accentTint;

  /// Denser base for popups, menus and sheets, which open over busy content
  /// and hold small text.
  static double get popupAlpha => PearStyles.spec.popupAlpha;

  /// Light catching the top edge: the highlight is brightest at the rim and
  /// is gone by [sheenReach] of the panel's height, so the body stays clear.
  static double get sheenTop => PearStyles.spec.sheenTop;
  static double get sheenBottom => PearStyles.spec.sheenBottom;
  static const double sheenReach = 0.22;

  /// Hairline edge. Brighter on top, like light catching the rim.
  static double get edgeTop => PearStyles.spec.edgeTop;
  static double get edge => PearStyles.spec.edge;

  /// Corner radius of floating chrome: side rail, nav bar, mini player.
  static const double floatingRadius = 20;

  /// Inner margin of the phone dock (mini player over nav bar): the cover,
  /// the hairline and the selected tab all sit this far in, and their corners
  /// use [dockInnerRadius] so they run parallel to the dock's own.
  static const double dockInset = 10;
  static const double dockInnerRadius = floatingRadius - dockInset;

  /// Resting fill for cards and rows that sit on the backdrop without a blur.
  static double get cardFill => PearStyles.spec.cardFill;

  /// Idle card body: lit from the top so rows read as raised glass instead of
  /// a flat sheet. Same average strength as [cardFill].
  static LinearGradient get cardSheen => PearStyles.spec.cardSheen;

  /// Hairline rim for card rows.
  static Color get cardRim =>
      Color.fromRGBO(255, 255, 255, PearStyles.spec.cardRim);

  /// Corner radius of the selected-tab pill, the same on the phone bar and the
  /// side rail so the two read as one shape. On the phone bar it is also the
  /// bar's radius minus the gap around the pill, so the corners run concentric.
  static const double selectionPillRadius = 15;

  /// [radius] in the current style: angular styles square every corner off
  /// to a 2px soften.
  static double r(double radius) =>
      PearStyles.spec.angular ? math.min(radius, 2) : radius;

  /// The one corner an angular panel cuts off (bottom right), and its fill.
  static const double cut = 10;
  static const Color angularPanel = Color(0xFF1B1C1F);

  /// An angular panel's outline: square, one cut corner, a thin light line.
  static ShapeBorder angularShape() => BeveledRectangleBorder(
        borderRadius: const BorderRadius.only(
          bottomRight: Radius.circular(cut),
        ),
        side: BorderSide(color: Colors.white.withValues(alpha: edge)),
      );

  /// The selected-tab pill, shared by the bottom nav bar and the side rail:
  /// the accent at one strength, edged by the same hairline as the panels
  /// rather than an accent outline. [radius] is normally
  /// [selectionPillRadius].
  static BoxDecoration selectionPill(
    ColorScheme scheme, {
    required double radius,
  }) =>
      PearStyles.spec.angular
          // A square highlight with the accent as a bar along its foot.
          ? BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              border: Border(
                bottom: BorderSide(color: scheme.primary, width: 2),
              ),
            )
          : BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: Colors.white.withValues(alpha: edge),
          width: 1,
        ),
      );
}

/// The grain tile: 128 px of grey noise, drawn at one image pixel per screen
/// pixel over the backdrop and the glass panels.
const String pearGrainAsset = 'assets/pear_grain.png';

/// Whether glass surfaces should skip the blur (Reduced Effects setting).
bool pearReducedEffects(BuildContext context) => context
    .select<AppController?, bool>((c) => c?.identity.reducedEffects ?? false);

/// Which edges of a [PearGlass] panel draw the hairline rim.
enum PearGlassEdge {
  /// Rounded floating panel: a full rim, brighter along the top.
  all,

  /// Window-wide strip at the top: only the bottom edge, facing the content.
  bottom,

  /// Window-wide strip at the bottom: only the top edge.
  top,
}

/// A frosted glass panel.
///
/// [tint] shifts the panel's base colour (the mini player uses the song's
/// artwork wash); by default it follows the theme's surface.
class PearGlass extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final Color? tint;
  final PearGlassEdge edge;

  /// Blur what lies behind the panel. Only worth it where content scrolls
  /// underneath; see the library comment.
  final bool blur;

  /// Strength of the dark base under the sheen; defaults to
  /// [PearGlassTokens.baseAlpha].
  final double? opacity;

  /// False draws only [child]: for a bar that sits inside a larger panel
  /// (the phone dock) and must not paint a second glass surface.
  final bool surface;

  const PearGlass({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.tint,
    this.edge = PearGlassEdge.all,
    this.blur = false,
    this.opacity,
    this.surface = true,
  });

  /// The panel fill: a sheen gradient over the blurred backdrop, or an opaque
  /// colour when the blur is off.
  static BoxDecoration fill(
    ColorScheme scheme, {
    required bool reduced,
    Color? tint,
    BorderRadius? borderRadius,
    double? opacity,
    double grainScale = 1,
  }) {
    final base = tint ??
        Color.alphaBlend(
          scheme.primary.withValues(alpha: PearGlassTokens.accentTint),
          scheme.surface,
        );
    final alpha = opacity ?? PearGlassTokens.baseAlpha;
    if (reduced) {
      return BoxDecoration(
        color: Color.alphaBlend(
          Colors.white.withValues(alpha: 0.05),
          tint ?? PlayerTheme.cardFillOpaque(scheme),
        ),
        borderRadius: borderRadius,
      );
    }
    return BoxDecoration(
      borderRadius: borderRadius,
      // Fine grain over the sheen, one grain pixel per screen pixel, so the
      // panel has a surface instead of a smooth gradient. Static, so it costs
      // one textured rectangle.
      image: DecorationImage(
        image: const AssetImage(pearGrainAsset),
        repeat: ImageRepeat.repeat,
        opacity: PearStyles.spec.grainAlpha,
        filterQuality: FilterQuality.none,
        scale: grainScale,
      ),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.alphaBlend(
            Colors.white.withValues(alpha: PearGlassTokens.sheenTop),
            base.withValues(alpha: alpha),
          ),
          base.withValues(alpha: alpha),
          Color.alphaBlend(
            Colors.white.withValues(alpha: PearGlassTokens.sheenBottom),
            base.withValues(alpha: (alpha + 0.08).clamp(0.0, 1.0)),
          ),
        ],
        stops: const [0, PearGlassTokens.sheenReach, 1],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!surface) return child;
    if (PearStyles.spec.angular) return _angular(context);
    final scheme = Theme.of(context).colorScheme;
    final reduced = pearReducedEffects(context) || PearStyles.spec.flat;

    Widget panel = DecoratedBox(
      decoration: fill(
        scheme,
        reduced: reduced,
        tint: tint,
        borderRadius: borderRadius,
        opacity: opacity,
        grainScale: MediaQuery.devicePixelRatioOf(context),
      ),
      child: child,
    );

    panel = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: switch (edge) {
        PearGlassEdge.all => _RimDecoration(borderRadius: borderRadius),
        PearGlassEdge.bottom => BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Colors.white.withValues(alpha: PearGlassTokens.edge),
            ),
          ),
        ),
        PearGlassEdge.top => BoxDecoration(
          border: Border(
            top: BorderSide(
              color: Colors.white.withValues(alpha: PearGlassTokens.edge),
            ),
          ),
        ),
      },
      child: panel,
    );

    if (reduced || !blur) {
      if (borderRadius != BorderRadius.zero) {
        panel = ClipRRect(borderRadius: borderRadius, child: panel);
      }
    } else {
      panel = ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: PearGlassTokens.blur,
            sigmaY: PearGlassTokens.blur,
            tileMode: TileMode.mirror,
          ),
          child: panel,
        ),
      );
    }

    return panel;
  }

  /// Angular styles: an opaque graphite panel. A floating panel is square
  /// with one cut corner; a window-wide strip keeps only its inner edge.
  Widget _angular(BuildContext context) {
    if (edge != PearGlassEdge.all) {
      final line = BorderSide(
        color: Colors.white.withValues(alpha: PearGlassTokens.edge),
      );
      return DecoratedBox(
        decoration: BoxDecoration(
          color: PearGlassTokens.angularPanel,
          border: edge == PearGlassEdge.top
              ? Border(top: line)
              : Border(bottom: line),
        ),
        child: child,
      );
    }
    final shape = PearGlassTokens.angularShape();
    return CustomPaint(
      // The cut corner carries the accent: a short stroke along the bevel.
      foregroundPainter: _CutStrokePainter(
        Theme.of(context).colorScheme.primary,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: PearGlassTokens.angularPanel,
          shape: shape,
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: child,
        ),
      ),
    );
  }
}

/// A 1px rounded rim, brighter along the top edge.
class _RimDecoration extends Decoration {
  final BorderRadius borderRadius;
  const _RimDecoration({required this.borderRadius});

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _RimPainter(borderRadius);
}

class _RimPainter extends BoxPainter {
  final BorderRadius borderRadius;
  _RimPainter(this.borderRadius);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final rect = (offset & size).deflate(0.5);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: PearGlassTokens.edgeTop),
          Colors.white.withValues(alpha: PearGlassTokens.edge),
          Colors.white.withValues(alpha: PearGlassTokens.edge * 0.8),
        ],
        stops: const [0, 0.35, 1],
      ).createShader(rect);
    canvas.drawRRect(borderRadius.toRRect(rect), paint);
  }
}

/// How list rows below this widget draw their body. Without one, rows are
/// divided: flat on the page with a hairline between them, and only the
/// playing or selected row keeps a fill. [flat] drops the hairline; with
/// neither set, every row is a glass card (sheen and rim), the look before
/// 2026-10-18, kept for the design gallery.
class PearRowLook extends InheritedWidget {
  const PearRowLook({
    super.key,
    this.flat = false,
    this.divided = false,
    required super.child,
  });

  final bool flat;
  final bool divided;

  static PearRowLook? _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PearRowLook>();

  static bool flatOf(BuildContext context) {
    final look = _of(context);
    return look == null || look.flat || look.divided;
  }

  static bool dividedOf(BuildContext context) => _of(context)?.divided ?? true;

  /// Width of the index column ("01") angular styles put before the cover.
  static const double numberWidth = 28;

  /// Corner radius of a row (its body and its hover fill).
  static double radius() => PearGlassTokens.r(14);

  /// A song row's body in the current look and style. Every variant keeps a
  /// 1px edge (painted or not) so the row stays [PearRow.extent] tall.
  static BoxDecoration body(
    BuildContext context, {
    required bool current,
    bool selected = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final flat = flatOf(context);
    final selectedFill = selected && !current
        ? scheme.primaryContainer.withValues(alpha: 0.22)
        : null;
    if (PearStyles.spec.angular) {
      // Square, no sheen; the playing row gets a faint fill and the accent
      // bar drawn by [accentBar].
      return BoxDecoration(
        color: current ? Colors.white.withValues(alpha: 0.05) : selectedFill,
        border: Border.all(color: Colors.transparent),
      );
    }
    return BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      // A top-lit glass sheen when idle (card rows), the accent gradient when
      // this row is playing.
      gradient: current
          ? LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                scheme.primary.withValues(alpha: 0.34),
                scheme.primary.withValues(alpha: 0.10),
              ],
            )
          : selected || flat
          ? null
          : PearGlassTokens.cardSheen,
      color: selectedFill,
      border: Border.all(
        color: flat ? Colors.transparent : PearGlassTokens.cardRim,
      ),
    );
  }

  /// The notch on the left edge of the playing row in angular styles;
  /// nothing otherwise. Goes first in the row's stack.
  static Widget accentBar(BuildContext context, {required bool current}) =>
      current && PearStyles.spec.angular
          ? Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: PearRowNotch(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            )
          : const SizedBox.shrink();

  @override
  bool updateShouldNotify(PearRowLook oldWidget) =>
      flat != oldWidget.flat || divided != oldWidget.divided;
}

/// Draws the hairline under a row when its [PearRowLook] is divided: from the
/// title's start to the row's end, over the row's own gap so the row keeps
/// its height ([PearRow.extent]).
class PearRowRule extends StatelessWidget {
  const PearRowRule({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => PearRowLook.dividedOf(context)
      ? CustomPaint(
          // Over the see-through styles the backdrop washes a faint line
          // out, so it is a little stronger there than on Solid.
          foregroundPainter: _RowRulePainter(
            PearStyles.spec.flat ? 0.07 : 0.10,
            indent: PearStyles.spec.angular
                ? _RowRulePainter.baseIndent + PearRowLook.numberWidth
                : _RowRulePainter.baseIndent,
          ),
          child: child,
        )
      : child;
}

class _RowRulePainter extends CustomPainter {
  const _RowRulePainter(this.alpha, {required this.indent});

  final double alpha;
  final double indent;

  /// Where the title starts: row inset, content padding and the cover.
  static const double baseIndent = 80;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height - 0.5;
    canvas.drawLine(
      Offset(indent, y),
      Offset(size.width - 16, y),
      Paint()
        ..color = Colors.white.withValues(alpha: alpha)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _RowRulePainter oldDelegate) =>
      oldDelegate.alpha != alpha || oldDelegate.indent != indent;
}

/// Viewfinder corners for angular styles: a short L at each corner of the
/// child, [outset] outside it, instead of a full outline.
class PearCornerBrackets extends StatelessWidget {
  const PearCornerBrackets({
    super.key,
    required this.child,
    this.outset = 6,
    this.arm = 14,
  });

  final Widget child;
  final double outset;
  final double arm;

  @override
  Widget build(BuildContext context) => CustomPaint(
        foregroundPainter: _BracketPainter(
          color: Colors.white.withValues(alpha: 0.55),
          outset: outset,
          arm: arm,
        ),
        child: child,
      );
}

class _BracketPainter extends CustomPainter {
  const _BracketPainter({
    required this.color,
    required this.outset,
    required this.arm,
  });

  final Color color;
  final double outset;
  final double arm;

  @override
  void paint(Canvas canvas, Size size) {
    final r = (Offset.zero & size).inflate(outset);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    final path = Path()
      ..moveTo(r.left, r.top + arm)
      ..lineTo(r.left, r.top)
      ..lineTo(r.left + arm, r.top)
      ..moveTo(r.right - arm, r.top)
      ..lineTo(r.right, r.top)
      ..lineTo(r.right, r.top + arm)
      ..moveTo(r.right, r.bottom - arm)
      ..lineTo(r.right, r.bottom)
      ..lineTo(r.right - arm, r.bottom)
      ..moveTo(r.left + arm, r.bottom)
      ..lineTo(r.left, r.bottom)
      ..lineTo(r.left, r.bottom - arm);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BracketPainter old) =>
      old.color != color || old.outset != outset || old.arm != arm;
}

/// A small block of diagonal stripes in the accent: the angular styles' tag
/// mark (headers, the dock), like a warning label on equipment.
class PearStripes extends StatelessWidget {
  const PearStripes({super.key, this.width = 26, this.height = 9, this.color});

  final double width;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: _StripePainter(
            color ?? Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}

class _StripePainter extends CustomPainter {
  const _StripePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.2;
    for (var x = -size.height; x < size.width + size.height; x += 5) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StripePainter old) => old.color != color;
}

/// The playing-row marker in angular styles: a small notch cut into the
/// row's left edge instead of a full-height bar.
class PearRowNotch extends StatelessWidget {
  const PearRowNotch({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 7,
        height: 12,
        child: CustomPaint(painter: _NotchPainter(color)),
      );
}

class _NotchPainter extends CustomPainter {
  const _NotchPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(size.width, size.height / 2)
        ..lineTo(0, size.height)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _NotchPainter old) => old.color != color;
}

class _CutStrokePainter extends CustomPainter {
  const _CutStrokePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // A small registration plus inside the opposite (top-left) corner.
    if (size.width > 60 && size.height > 30) {
      const at = Offset(7, 7);
      canvas.drawPath(
        Path()
          ..moveTo(at.dx - 3, at.dy)
          ..lineTo(at.dx + 3, at.dy)
          ..moveTo(at.dx, at.dy - 3)
          ..lineTo(at.dx, at.dy + 3),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.30)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }
    const c = PearGlassTokens.cut;
    canvas.drawLine(
      Offset(size.width - c, size.height),
      Offset(size.width, size.height - c),
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.square,
    );
  }

  @override
  bool shouldRepaint(covariant _CutStrokePainter old) => old.color != color;
}

/// A spec-sheet rule for angular styles: a hairline with an accent tick at its
/// start and a short stripe block at its end. Sits under a list's controls.
class PearSpecRule extends StatelessWidget {
  const PearSpecRule({super.key});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          Container(width: 14, height: 2, color: accent),
          Expanded(
            child: Container(
              height: 1,
              color: Colors.white.withValues(alpha: PearGlassTokens.edge),
            ),
          ),
          const SizedBox(width: 6),
          PearStripes(
            width: 22,
            height: 5,
            color: Colors.white.withValues(alpha: 0.28),
          ),
        ],
      ),
    );
  }
}

/// A small count badge ("14", "12 / 14"). Angular styles draw it as a solid
/// accent block with dark figures and one cut corner, like a status tag on
/// equipment; the rest keep a soft accent tint.
class PearCountChip extends StatelessWidget {
  const PearCountChip(this.text, {super.key, required this.color, this.fontSize = 10.5});

  final String text;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final angular = PearStyles.spec.angular;
    final label = Text(
      text,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w800,
        letterSpacing: angular ? 0.6 : 0,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: angular
            ? (color.computeLuminance() > 0.35
                ? const Color(0xFF15161A)
                : Colors.white)
            : color,
      ),
    );
    if (angular) {
      return Container(
        padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
        decoration: ShapeDecoration(
          color: color,
          shape: const BeveledRectangleBorder(
            borderRadius: BorderRadius.only(bottomRight: Radius.circular(5)),
          ),
        ),
        child: label,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: label,
    );
  }
}
