import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:peerm_app/services/artwork_palette.dart';
import 'package:peerm_app/services/player_theme.dart';

/// Guards the app-wide theme transition: the colour follows the playing song's
/// artwork, animated by lerping the ColorScheme and rebuilding the theme from
/// it each frame. Regression: (1) a generic `Tween<ThemeData>` throws
/// "Cannot lerp between ThemeData#..." (red screen) — fixed by the custom
/// tween; (2) `ThemeData.lerp` binary-switches derived component themes at
/// t=0.5, snapping the colour on desktop — fixed by lerping only the scheme
/// via [PlayerTheme.buildFromScheme].
void main() {
  test('colour transition is continuous and cheap (copyWith + ColorScheme.lerp)',
      () {
    final a = buildTheme(ArtworkPalette.fallback);
    final b = buildTheme(const Color(0xFF4CAF50));

    // Exactly what the tween does each frame: lerp the scheme, copyWith onto
    // the target. No full ThemeData rebuild (that janked on mobile), no
    // ThemeData.lerp mid-fade snap.
    final mid = b.copyWith(
        colorScheme: ColorScheme.lerp(a.colorScheme, b.colorScheme, 0.5));
    final end = b.copyWith(
        colorScheme: ColorScheme.lerp(a.colorScheme, b.colorScheme, 1.0));

    // Must not throw; the midpoint differs from both endpoints and the end
    // matches the target scheme.
    expect(mid.colorScheme.primary, isNot(a.colorScheme.primary));
    expect(mid.colorScheme.primary, isNot(b.colorScheme.primary));
    expect(end.colorScheme.primary, b.colorScheme.primary);
  });
}

/// Mirrors `PlayerTheme._build` (controlAccent -> fromSeed -> buildFromScheme)
/// so the test exercises the real theme shape.
ThemeData buildTheme(Color accent) => PlayerTheme.buildFromScheme(
      ColorScheme.fromSeed(
        seedColor: ArtworkPalette.controlAccent(accent),
        brightness: Brightness.dark,
      ),
    );
