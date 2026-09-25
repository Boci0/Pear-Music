/// The soft glass material: frosted, see-through panels that let the
/// artwork-tinted backdrop glow through.
///
/// Floating chrome (side rail, nav bar, mini player, Now Playing pane, menu
/// and status strips) is built from [PearGlass] so every panel shares one
/// blur, one fill and one edge. With Reduced Effects on, the blur is dropped
/// and the fill turns opaque, so low-end devices pay nothing for the look.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/player_theme.dart';

/// Values shared by every glass surface.
class PearGlassTokens {
  PearGlassTokens._();

  /// Backdrop blur strength. High enough that list text scrolling under the
  /// mini player reads as colour, not as legible letters.
  static const double blur = 28;

  /// Tint laid over the blurred backdrop: a dark base so text stays readable,
  /// with a faint white sheen that fades from top to bottom.
  static const double baseAlpha = 0.55;
  static const double sheenTop = 0.08;
  static const double sheenBottom = 0.03;

  /// Hairline edge. Brighter on top, like light catching the rim.
  static const double edgeTop = 0.16;
  static const double edge = 0.07;

  /// Corner radius of floating chrome: side rail, nav bar, mini player.
  static const double floatingRadius = 20;

  /// Resting fill for cards and rows that sit on the backdrop without a blur.
  static const double cardFill = 0.045;

  static final List<BoxShadow> shadow = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.35),
      blurRadius: 32,
      offset: const Offset(0, 12),
    ),
  ];
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
  final bool shadow;
  final PearGlassEdge edge;

  const PearGlass({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.tint,
    this.shadow = true,
    this.edge = PearGlassEdge.all,
  });

  /// The panel fill: a sheen gradient over the blurred backdrop, or an opaque
  /// colour when the blur is off.
  static BoxDecoration fill(
    ColorScheme scheme, {
    required bool reduced,
    Color? tint,
    BorderRadius? borderRadius,
  }) {
    final base = tint ?? scheme.surface;
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
            base.withValues(alpha: PearGlassTokens.baseAlpha),
          ),
          Color.alphaBlend(
            Colors.white.withValues(alpha: PearGlassTokens.sheenBottom),
            base.withValues(alpha: PearGlassTokens.baseAlpha + 0.1),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduced = pearReducedEffects(context);

    Widget panel = DecoratedBox(
      decoration: fill(
        scheme,
        reduced: reduced,
        tint: tint,
        borderRadius: borderRadius,
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

    if (reduced) {
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

    if (!shadow) return panel;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: PearGlassTokens.shadow,
      ),
      child: panel,
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
