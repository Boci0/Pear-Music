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

  static final Map<Color, ThemeData> _cache = {};

  static ThemeData _build(Color accent) {
    final control = ArtworkPalette.controlAccent(accent);
    return _cache.putIfAbsent(control, () {
      final scheme = ColorScheme.fromSeed(
        seedColor: control,
        brightness: Brightness.dark,
      );
      return ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF1E1E1E),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
          ),
        ),
      );
    });
  }

  void _onPlayerChanged() {
    final song = _player.currentSong;
    if (song == null) {
      // Nothing playing -> back to the default purple theme.
      _apply(ArtworkPalette.fallback);
      return;
    }
    ArtworkPalette.dominant(song).then(_apply);
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
