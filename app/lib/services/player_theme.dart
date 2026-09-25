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
    ArtworkPalette.paletteNotifier.addListener(_onPaletteUpdated);
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
  /// Blends the song accent into a neutral colour: the single place the
  /// "music colours the room" strength lives. Used by the theme itself and by
  /// the shell chrome (menu strip, status bar) so everything tints together.
  static Color ambientBlend(
    ColorScheme scheme,
    Color base, {
    double alpha = 0.08,
  }) {
    return Color.alphaBlend(scheme.primary.withValues(alpha: alpha), base);
  }

  /// Opaque equivalent of the translucent card fill, for chrome that floats
  /// over scrolling content (nav bar, mini player, side rail): the cards' own
  /// tone, but nothing shows through.
  static Color cardFillOpaque(ColorScheme scheme) => Color.alphaBlend(
    scheme.surfaceContainerHighest.withValues(alpha: 0.5),
    scheme.surface,
  );

  static ThemeData buildFromScheme(ColorScheme scheme) {
    // Night ramp: canvas, card and chrome sit a whisker apart so a deep, quiet
    // room still reads in layers. The accent tint below is what moves.
    const baseBg = Color(0xFF0A0A0C);
    const baseSurface = Color(0xFF121215);
    const baseHighlight = Color(0xFF18181B);

    // The music colours the room: the canvas and every neutral surface pick up
    // a whisper of the song's accent, so the whole window follows the artwork
    // instead of staying pure grey. Idle uses the emerald fallback accent.
    final bgDark = ambientBlend(scheme, baseBg);
    final surfaceDark = ambientBlend(scheme, baseSurface, alpha: 0.06);
    final surfaceHighlight = ambientBlend(scheme, baseHighlight, alpha: 0.06);

    return ThemeData(
      useMaterial3: true,
      hoverColor: Colors.white.withValues(alpha: 0.04),
      // Keyboard focus gets its own subtle fill (plus the Material focus
      // overlay on icon buttons) so tabbing through the desktop shell is
      // visible without being loud.
      focusColor: Colors.white.withValues(alpha: 0.06),
      splashColor: scheme.primary.withValues(alpha: 0.08),
      highlightColor: Colors.transparent,
      colorScheme: scheme.copyWith(
        surface: bgDark,
        surfaceContainerLow: const Color(0xFF0E0E10),
        surfaceContainer: surfaceDark,
        surfaceContainerHigh: surfaceHighlight,
        surfaceContainerHighest: const Color(0xFF202024),
      ),
      // Screens stay transparent so PearBackdrop can paint the canvas (and its
      // watermark) once, behind every route.
      scaffoldBackgroundColor: Colors.transparent,
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return scheme.primary.withValues(alpha: 0.14);
            }
            if (states.contains(WidgetState.focused)) {
              return Colors.white.withValues(alpha: 0.10);
            }
            if (states.contains(WidgetState.hovered)) {
              return Colors.white.withValues(alpha: 0.06);
            }
            return Colors.transparent;
          }),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _FastFadePageTransitionsBuilder(),
          TargetPlatform.iOS: _FastFadePageTransitionsBuilder(),
          TargetPlatform.windows: _FastFadePageTransitionsBuilder(),
          TargetPlatform.linux: _FastFadePageTransitionsBuilder(),
          TargetPlatform.macOS: _FastFadePageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        // Transparent so the backdrop runs to the top edge instead of
        // stopping at a band behind the bar.
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 16,
      ),
      cardTheme: CardThemeData(
        // Same body as the list cards (playlist tile, song rows): one fill at
        // one radius, so the backdrop texture stays faintly visible through
        // the cards instead of being blocked by an opaque panel.
        color: surfaceHighlight.withValues(alpha: 0.5),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceDark,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        titleTextStyle: const TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      // Desktop menus (menu bar, sort, library profile, right-click context
      // menus) share one card look instead of the default flat Material menu.
      popupMenuTheme: PopupMenuThemeData(
        color: surfaceHighlight,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(surfaceHighlight),
          elevation: const WidgetStatePropertyAll(8),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 6),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceDark,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: scheme.primary.withValues(alpha: 0.6),
            width: 1.5,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceDark,
        selectedColor: scheme.primary.withValues(alpha: 0.18),
        secondarySelectedColor: scheme.primary.withValues(alpha: 0.18),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        labelStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: scheme.onSurface,
        ),
        secondaryLabelStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        showCheckmark: false,
      ),
      // Desktop scrollbars: thin, rounded, and only visible while the pointer
      // is near them, so long lists keep the borderless card look.
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.dragged) ||
              states.contains(WidgetState.hovered)) {
            return Colors.white.withValues(alpha: 0.30);
          }
          return Colors.white.withValues(alpha: 0.16);
        }),
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(999),
        trackVisibility: const WidgetStatePropertyAll(false),
        crossAxisMargin: 2,
      ),
      // Tooltips share the popup card material instead of the flat grey
      // Material default, and wait a beat so they do not flash while the
      // pointer crosses a toolbar.
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 420),
        showDuration: const Duration(seconds: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: surfaceHighlight,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        textStyle: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
      ),
      // The Explore search bar drops its elevated grey slab and matches the
      // borderless field the library header uses.
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(
          Colors.white.withValues(alpha: 0.06),
        ),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
        ),
        side: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return BorderSide(
              color: scheme.primary.withValues(alpha: 0.5),
            );
          }
          return BorderSide.none;
        }),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12),
        ),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 14)),
        hintStyle: WidgetStatePropertyAll(
          TextStyle(
            fontSize: 14,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      // Borderless segmented buttons (the lyrics colour picker) so the last
      // bordered control joins the app's chip language.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: const WidgetStatePropertyAll(BorderSide.none),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return scheme.primary.withValues(alpha: 0.20);
            }
            return Colors.white.withValues(alpha: 0.05);
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return scheme.primary;
            return scheme.onSurfaceVariant;
          }),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          visualDensity: VisualDensity.compact,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.primary;
          }
          return Colors.white.withValues(alpha: 0.4);
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.primary.withValues(alpha: 0.25);
          }
          return Colors.white.withValues(alpha: 0.08);
        }),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      dividerTheme: DividerThemeData(
        color: Colors.white.withValues(alpha: 0.05),
        thickness: 1,
        space: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF131315),
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
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaceDark,
        constraints: BoxConstraints(maxWidth: 640),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      iconTheme: IconThemeData(color: scheme.onSurface),
      primaryColor: scheme.primary,
    );
  }

  static ThemeData _build(Color accent) {
    final cached = _cache[accent];
    if (cached != null) return cached;
    final built = buildFromScheme(
      ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
    );
    // Bounded cache: evict the oldest accent so the cache can't grow without
    // bound as more songs with distinct artwork colours are played.
    if (_cache.length >= _cacheMax) {
      _cache.remove(_cache.keys.first);
    }
    _cache[accent] = built;
    return built;
  }

  void _onPaletteUpdated() {
    final song = _player.currentSong;
    if (song != null && ArtworkPalette.hasResolved(song)) {
      final color = ArtworkPalette.dominantSync(song);
      _apply(color);
    }
  }

  void _onPlayerChanged() {
    final song = _player.currentSong;
    final id = song?.id;
    if (id == _appliedSongId &&
        (song == null || ArtworkPalette.hasResolved(song))) {
      return;
    }
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
    ArtworkPalette.paletteNotifier.removeListener(_onPaletteUpdated);
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
        curve: Curves.easeOutQuad,
        reverseCurve: Curves.easeInQuad,
      ),
      child: child,
    );
  }
}
