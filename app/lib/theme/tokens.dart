/// Shared design tokens for Pear Music.
///
/// These are calibrated to the scale the UI already uses (settled over the
/// 2026-09 UI passes): adopting one of these tokens is value-preserving.
/// When you touch a file, prefer pulling the value from here over adding
/// another near-identical literal; when nothing genuinely fits, round to the
/// nearest token instead of introducing a new number.
///
/// Deliberately kept out of the roles below, and untouched where they are
/// used today: the popup-panel/inner-artwork radius (16) and the floating-bar
/// radius (20, side rail and mini player). New work picks from the roles.
library;

import 'package:flutter/material.dart';

/// Spacing steps, 4pt base.
class PearSpacing {
  PearSpacing._();

  /// Icon-to-label pairs and other tight pairs.
  static const double xs = 4;

  /// Default gap between related elements (artwork to text, chips).
  static const double sm = 8;

  /// Card/list padding; the gap between a list row's title and meta line.
  static const double md = 12;

  /// Module padding, section separation.
  static const double lg = 16;

  /// Sheet/dialog padding, empty-state spacing.
  static const double xl = 24;

  /// Wide-layout page margins.
  static const double xxl = 32;
}

/// Corner-radius roles. Pick by what the surface is, not by its size.
class PearRadius {
  PearRadius._();

  /// Small chips, badges, icon-button hit shapes.
  static const double chip = 8;

  /// Artwork thumbnails in list rows (44-48px).
  static const double thumb = 10;

  /// Song, queue and list rows, and buttons inside them.
  static const double row = 12;

  /// Search fields and filter pills.
  static const double field = 14;

  /// Content cards (settings, home panels).
  static const double card = 18;

  /// Dialogs, bottom sheets, the Now Playing pane.
  static const double sheet = 24;

  /// Fully rounded (capsule): accent bars, pills, the nav indicator.
  static const double pill = 999;

  static const BorderRadius chipAll = BorderRadius.all(Radius.circular(chip));
  static const BorderRadius thumbAll = BorderRadius.all(Radius.circular(thumb));
  static const BorderRadius rowAll = BorderRadius.all(Radius.circular(row));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}

/// Icon sizes, by the role the glyph plays.
class PearIconSize {
  PearIconSize._();

  /// Glyphs sitting inline next to text (source badges, dense row icons).
  static const double inline = 13;

  /// Row actions: favourite, more-options, playing indicator.
  static const double action = 18;

  /// Toolbars, navigation and rail items.
  static const double button = 22;

  /// Player transport buttons (previous / next in the pane).
  static const double transport = 28;

  /// The main play/pause glyph.
  static const double hero = 52;
}

/// Named text styles built from the theme's textTheme, so they stay themeable
/// (textScaler, contrast settings) while pinning sizes to one scale. The
/// values are the library rows' settled ones; that is what the rest of the
/// app converges on: title 15/w600, body 13, meta 12.5, label 12.
class PearText {
  /// List-row and card titles.
  final TextStyle title;

  /// Default row or paragraph text.
  final TextStyle body;

  /// Secondary line under a title (source, duration, played-ago).
  final TextStyle meta;

  /// Chips, tags and badge text.
  final TextStyle label;

  const PearText({
    required this.title,
    required this.body,
    required this.meta,
    required this.label,
  });

  factory PearText.of(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return PearText(
      title: (tt.titleMedium ?? const TextStyle()).copyWith(
        fontSize: 15,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      body: (tt.bodyMedium ?? const TextStyle()).copyWith(
        fontSize: 13,
        height: 1.3,
      ),
      meta: (tt.bodySmall ?? const TextStyle()).copyWith(
        fontSize: 12.5,
        height: 1.25,
      ),
      label: (tt.labelSmall ?? const TextStyle()).copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

/// Overlay alphas for the matte material set (borderless fills).
class PearOverlay {
  PearOverlay._();

  /// Hover fill on list and queue rows (white over the surface).
  static const double hover = 0.055;
}
