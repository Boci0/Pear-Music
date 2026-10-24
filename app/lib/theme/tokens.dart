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

import 'dart:math' as math;


import 'package:flutter/foundation.dart';

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
/// Graphite squares every role off to a 2px soften.
class PearRadius {
  PearRadius._();

  static double _style(double radius) => math.min(radius, 2);

  /// Small chips, badges, icon-button hit shapes.
  static double get chip => _style(8);

  /// Artwork thumbnails in list rows (44-48px).
  static double get thumb => _style(10);

  /// Song, queue and list rows, and buttons inside them.
  static double get row => _style(12);

  /// Search fields and filter pills.
  static double get field => _style(14);

  /// Content cards (settings, home panels).
  static double get card => _style(18);

  /// Dialogs, bottom sheets, the Now Playing pane.
  static double get sheet => _style(24);

  /// Fully rounded (capsule): accent bars, pills, the nav indicator.
  static double get pill => _style(999);

  static BorderRadius get chipAll => BorderRadius.circular(chip);
  static BorderRadius get thumbAll => BorderRadius.circular(thumb);
  static BorderRadius get rowAll => BorderRadius.circular(row);
  static BorderRadius get pillAll => BorderRadius.circular(pill);
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

/// Song card rows (`SongTile`, `YouTubeSongTile`, the playlist reorder row):
/// the card, the gap above and below it, and the pitch every fixed-extent
/// list or grid of them must use. A fixed extent hands each row tight
/// constraints, so a pitch smaller than [extent] squeezes the card itself.
class PearRow {
  PearRow._();

  /// Desktop lists are read with a mouse on a tall screen: shorter rows fit
  /// more songs. Touch platforms keep the 64 px card.
  static bool get dense => switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.macOS => true,
    _ => false,
  };

  /// Card height, rim included.
  static double get card => dense ? 48 : 64;

  /// Cover size inside a row.
  static double get cover => dense ? 36 : 44;

  /// Card rim width (the 1 px `Border.all` on the card decoration), which
  /// the decoration adds as padding around the content.
  static const double rim = 1;

  /// Height of the content inside the rim.
  static double get content => card - 2 * rim;

  /// Vertical padding above and below the card.
  static const double gap = 4;

  /// Row pitch: `itemExtent` / `mainAxisExtent` for song lists and grids.
  static double get extent => card + 2 * gap;
}
