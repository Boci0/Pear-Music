import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:peerm_app/services/artwork_palette.dart';

/// Guards the app-wide theme transition: the colour follows the playing song's
/// artwork, animated via ThemeData.lerp. Regression: using a generic
/// `Tween<ThemeData>` (whose default lerp does `begin + (end - begin) * t`)
/// throws "Cannot lerp between ThemeData#..." the instant the song changes and
/// shows a red error screen. The fix is to delegate to ThemeData.lerp, so this
/// test asserts two different-accent themes (as PlayerTheme._build produces)
/// can be lerped without throwing.
void main() {
  test('themes from different artwork accents lerp smoothly (no red screen)',
      () {
    final a = buildTheme(ArtworkPalette.fallback);
    final b = buildTheme(const Color(0xFF4CAF50));

    // Must not throw.
    final mid = ThemeData.lerp(a, b, 0.5);
    final end = ThemeData.lerp(a, b, 1.0);

    // Midpoint colour differs from both endpoints, and the end matches b.
    expect(mid.colorScheme.primary, isNot(a.colorScheme.primary));
    expect(end.colorScheme.primary, b.colorScheme.primary);
  });
}

/// Mirrors `PlayerTheme._build` so the test exercises the real theme shape.
ThemeData buildTheme(Color accent) {
  final scheme = ColorScheme.fromSeed(
    seedColor: ArtworkPalette.controlAccent(accent),
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF121212),
  );
}
