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

  /// The selected-tab pill, shared by the bottom nav bar and the side rail:
  /// the accent at one strength, edged by the same hairline as the panels
  /// rather than an accent outline. [radius] is normally
  /// [selectionPillRadius].
  static BoxDecoration selectionPill(
    ColorScheme scheme, {
    required double radius,
  }) =>
      BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: Colors.white.withValues(alpha: edge),
          width: 1,
        ),
      );
}

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

  const PearGlass({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.tint,
    this.edge = PearGlassEdge.all,
    this.blur = false,
    this.opacity,
  });

  /// The panel fill: a sheen gradient over the blurred backdrop, or an opaque
  /// colour when the blur is off.
  static BoxDecoration fill(
    ColorScheme scheme, {
    required bool reduced,
    Color? tint,
    BorderRadius? borderRadius,
    double? opacity,
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
    final scheme = Theme.of(context).colorScheme;
    final reduced = pearReducedEffects(context) || PearStyles.spec.flat;

    Widget panel = DecoratedBox(
      decoration: fill(
        scheme,
        reduced: reduced,
        tint: tint,
        borderRadius: borderRadius,
        opacity: opacity,
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
