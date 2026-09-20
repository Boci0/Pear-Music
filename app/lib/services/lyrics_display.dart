import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which colour the lyrics text uses while a song plays.
enum LyricsColorMode {
  /// Follow the artwork brightness: dark text on bright covers, white text on
  /// dark covers. This is the automatic behaviour.
  auto,

  /// Always use light (white) text.
  light,

  /// Always use dark text.
  dark,
}

/// Persisted lyrics display preference shared by the lyrics view and the
/// Lyrics Options sheet.
class LyricsDisplay {
  LyricsDisplay._();

  static const String _key = 'peerm_lyrics_text_color';

  /// Current mode. Widgets listen to this and rebuild when it changes.
  static final ValueNotifier<LyricsColorMode> mode =
      ValueNotifier<LyricsColorMode>(LyricsColorMode.auto);

  /// Loads the persisted mode. Called once during bootstrap.
  static Future<void> init(SharedPreferences prefs) async {
    final raw = prefs.getString(_key);
    mode.value = LyricsColorMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => LyricsColorMode.auto,
    );
  }

  /// Updates and persists the mode.
  static Future<void> set(LyricsColorMode value) async {
    if (mode.value == value) return;
    mode.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, value.name);
  }

  /// Resolves whether the lyrics should use dark text for [mode].
  ///
  /// [artworkPrefersDarkText] is the automatic artwork-based guess, used as-is
  /// by [LyricsColorMode.auto].
  static bool resolveDarkText({
    required LyricsColorMode mode,
    required bool artworkPrefersDarkText,
  }) {
    switch (mode) {
      case LyricsColorMode.auto:
        return artworkPrefersDarkText;
      case LyricsColorMode.light:
        return false;
      case LyricsColorMode.dark:
        return true;
    }
  }
}
