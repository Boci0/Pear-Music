/// The Graphite material: opaque graphite panels with a thin light edge,
/// square corners and one cut corner, the app's only look.
///
/// Floating chrome (side rail, nav bar, mini player, Now Playing pane, menu
/// and status strips) is built from [PearGlass] so every panel shares one
/// fill and one edge.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';


/// Values shared by every panel.
class PearGlassTokens {
  PearGlassTokens._();

  /// Hairline edge of panels and rules.
  static const double edge = 0.12;

  /// Resting fill for cards and rows that sit on the page.
  static const double cardFill = 0.04;

  /// Hairline edge of tiles and cards.
  static const Color cardRim = Color.fromRGBO(255, 255, 255, 0.10);

  /// Corner radius of floating chrome before [r] squares it off: side rail,
  /// nav bar, mini player.
  static const double floatingRadius = 20;

  /// Inner margin of the phone dock (mini player over nav bar): the cover,
  /// the hairline and the selected tab all sit this far in.
  static const double dockInset = 10;
  static const double dockInnerRadius = floatingRadius - dockInset;

  /// [radius] squared off to a 2px soften: Graphite has no round corners.
  static double r(double radius) => math.min(radius, 2);

  /// The one corner a panel cuts off (bottom right), and its fill.
  static const double cut = 10;
  static const Color angularPanel = Color(0xFF1B1C1F);

  /// A panel's outline: square with a thin light line.
  static ShapeBorder angularShape() => RoundedRectangleBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: edge)),
      );

  /// The outline of the few hero surfaces (player cover frame, Continue
  /// listening card): square with one cut corner.
  static ShapeBorder heroShape() => BeveledRectangleBorder(
        borderRadius: const BorderRadius.only(
          bottomRight: Radius.circular(cut),
        ),
        side: BorderSide(color: Colors.white.withValues(alpha: edge)),
      );

  /// Navigation (phone bar, both rails) is the one rounded thing in the app:
  /// a capsule of [color], the accent tint ([navTint]) for the selected
  /// destination. Never animate its size; it only fades.
  static BoxDecoration navPill(Color color) => BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      );
  static Color navTint(ColorScheme scheme) =>
      scheme.primary.withValues(alpha: 0.16);

  /// The selected section in Settings' section list: a faint square
  /// highlight with the accent as a bar along its foot.
  static BoxDecoration selectionPill(ColorScheme scheme) => BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        border: Border(bottom: BorderSide(color: scheme.primary, width: 2)),
      );
}

/// Which edges of a [PearGlass] panel draw the hairline rim.
enum PearGlassEdge {
  /// Floating panel: a full edge, square with one cut corner.
  all,

  /// Window-wide strip at the top: only the bottom edge, facing the content.
  bottom,

  /// Window-wide strip at the bottom: only the top edge.
  top,
}

/// A Graphite panel: opaque graphite with a thin light edge. A floating
/// panel is square; a [hero] panel has one cut corner whose bevel carries the
/// accent. A window-wide strip keeps only its inner edge.
class PearGlass extends StatelessWidget {
  final Widget child;
  final PearGlassEdge edge;

  /// False draws only [child]: for a bar that sits inside a larger panel
  /// (the phone dock) and must not paint a second surface.
  final bool surface;

  /// True gives the cut corner and its accent stroke (hero surfaces only).
  final bool hero;

  const PearGlass({
    super.key,
    required this.child,
    this.edge = PearGlassEdge.all,
    this.surface = true,
    this.hero = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!surface) return child;
    // Rows and buttons inside paint their hover and press ink on this
    // Material; without it the ink lands on the Scaffold under the panel.
    final inked = Material(type: MaterialType.transparency, child: child);
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
        child: inked,
      );
    }
    final shape =
        hero ? PearGlassTokens.heroShape() : PearGlassTokens.angularShape();
    return CustomPaint(
      // The cut corner carries the accent: a short stroke along the bevel.
      foregroundPainter: hero
          ? _CutStrokePainter(Theme.of(context).colorScheme.primary)
          : null,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: PearGlassTokens.angularPanel,
          shape: shape,
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: inked,
        ),
      ),
    );
  }
}

/// How list rows below this widget draw their body. Without one, rows are
/// divided: flat on the page with a hairline between them. [divided] false
/// drops the hairline (the design gallery's plain rows).
class PearRowLook extends InheritedWidget {
  const PearRowLook({super.key, this.divided = false, required super.child});

  final bool divided;

  static bool dividedOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PearRowLook>()?.divided ??
      true;

  /// Width of the index column ("01") before the cover.
  static const double numberWidth = 28;

  /// Corner radius of a row (its body and its hover fill).
  static double radius() => PearGlassTokens.r(14);

  /// A song row's body: square with no sheen; the playing row gets a faint
  /// fill (and the notch from [accentBar]), a selected row a light accent.
  /// Every variant keeps a 1px edge so the row stays [PearRow.extent] tall.
  static BoxDecoration body(
    BuildContext context, {
    required bool current,
    bool selected = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: current
          ? Colors.white.withValues(alpha: 0.05)
          : selected
          ? scheme.primaryContainer.withValues(alpha: 0.22)
          : null,
      border: Border.all(color: Colors.transparent),
    );
  }

  /// The notch on the left edge of the playing row. Goes first in the row's
  /// stack.
  static Widget accentBar(BuildContext context, {required bool current}) =>
      current
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
      divided != oldWidget.divided;
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
          foregroundPainter: _RowRulePainter(
            0.07,
            indent: _RowRulePainter.baseIndent + PearRowLook.numberWidth,
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

/// The playing-row marker: a small notch cut into the
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

/// A spec-sheet rule: a hairline with an accent tick at its
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
        ],
      ),
    );
  }
}

/// A small count badge ("14", "12 / 14"): a solid accent block with dark
/// figures and square, like a status tag on equipment.
class PearCountChip extends StatelessWidget {
  const PearCountChip(this.text, {super.key, required this.color, this.fontSize = 10.5});

  final String text;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
      decoration: ShapeDecoration(
        color: color,
        shape: const RoundedRectangleBorder(),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: color.computeLuminance() > 0.35
              ? const Color(0xFF15161A)
              : Colors.white,
        ),
      ),
    );
  }
}

/// A phone held sideways (or any window under 500 px tall): headings and top
/// bars shrink so the lists start near the top.
bool pearShortScreen(BuildContext context) =>
    MediaQuery.sizeOf(context).height < 500;
