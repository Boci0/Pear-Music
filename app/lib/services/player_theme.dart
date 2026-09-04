import 'package:flutter/material.dart';

import 'artwork_palette.dart';
import 'player_service.dart';

/// App-wide theme that follows the currently-playing song's artwork colour.
///
/// The whole app (home, playlists, settings, player) stays dark but its colour
/// scheme is re-seeded from a softened version of the current song's dominant
/// colour, so the album art tints the entire UI without losing dark mode.
///
/// Rebuilds are cached per accent and only happen when the song (and thus its
/// colour) actually changes, so there's no per-frame theme work.
class PlayerTheme extends ChangeNotifier {
  PlayerTheme(PlayerService player) : _player = player {
    _player.addListener(_onPlayerChanged);
    _onPlayerChanged();
  }

  final PlayerService _player;
  ThemeData _theme = _build(ArtworkPalette.fallback);
  ThemeData get theme => _theme;

  /// Song id whose colour is currently applied. Guards against re-resolving the
  /// artwork colour on every player notify — play/pause/seek fire constantly,
  /// but the colour only needs to change when the SONG changes.
  String? _appliedSongId;

  static final Map<Color, ThemeData> _cache = {};
  static const int _cacheMax = 32;

  /// Builds the app theme around [scheme]: the fixed dark structure (scaffold,
  /// card, app bar) plus this color scheme. BOTH the per-song target theme and
  /// every animation frame of a colour transition go through here, so derived
  /// colours (primaryColor, textTheme, iconTheme, inputDecorationTheme, ...)
  /// always match the scheme being shown. That keeps the transition a smooth
  /// fade instead of a snap at the halfway point.
  static ThemeData buildFromScheme(ColorScheme scheme) {
    const bgDark = Color(0xFF0F0F12);
    const surfaceDark = Color(0xFF18181E);
    const surfaceHighlight = Color(0xFF22222A);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme.copyWith(
        surface: bgDark,
        surfaceContainerLow: const Color(0xFF141418),
        surfaceContainer: surfaceDark,
        surfaceContainerHigh: surfaceHighlight,
      ),
      scaffoldBackgroundColor: bgDark,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _FastFadePageTransitionsBuilder(),
          TargetPlatform.iOS: _FastFadePageTransitionsBuilder(),
          TargetPlatform.windows: _FastFadePageTransitionsBuilder(),
          TargetPlatform.linux: _FastFadePageTransitionsBuilder(),
          TargetPlatform.macOS: _FastFadePageTransitionsBuilder(),
        },
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bgDark,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: surfaceDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.07)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceDark,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceDark,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:
              BorderSide(color: scheme.primary.withValues(alpha: 0.6), width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF141418),
        elevation: 0,
        height: 65,
        indicatorColor: scheme.primary.withValues(alpha: 0.2),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surfaceHighlight,
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
    );
  }

  static ThemeData _build(Color accent) {
    final control = ArtworkPalette.controlAccent(accent);
    final cached = _cache[control];
    if (cached != null) return cached;
    final built = buildFromScheme(ColorScheme.fromSeed(
      seedColor: control,
      brightness: Brightness.dark,
    ));
    // Bounded cache: evict the oldest accent so the cache can't grow without
    // bound as more songs with distinct artwork colours are played.
    if (_cache.length >= _cacheMax) {
      _cache.remove(_cache.keys.first);
    }
    _cache[control] = built;
    return built;
  }

  void _onPlayerChanged() {
    final song = _player.currentSong;
    final id = song?.id;
    if (id == _appliedSongId) return; // same song — colour already applied
    _appliedSongId = id;
    if (song == null) {
      // Nothing playing -> back to the default purple theme.
      _apply(ArtworkPalette.fallback);
      return;
    }
    ArtworkPalette.dominant(song).then(_apply);
  }

  /// Forces the theme to re-resolve from the current song. Called on app
  /// resume so the colour scheme is restored even if caches were cleared.
  void reapply() {
    _appliedSongId = null;
    _onPlayerChanged();
  }

  void _apply(Color accent) {
    final next = _build(accent);
    if (!identical(next, _theme)) {
      _theme = next;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayerChanged);
    super.dispose();
  }
}

/// Lightweight 150ms opacity fade transition for zero-lag 60fps route pushes.
class _FastFadePageTransitionsBuilder extends PageTransitionsBuilder {
  const _FastFadePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      ),
      child: child,
    );
  }
}
