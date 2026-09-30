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

/// How the current line lights up as it is sung.
enum WordGlowMode {
  /// Word by word: by the lyrics' own word timing when they carry it,
  /// otherwise by an estimate. (Stored as "estimated"; the former "exact"
  /// setting, which lit untimed lines all at once, loads as this.)
  estimated,

  /// The whole line lights up at once.
  off,
}

/// Persisted lyrics display preference shared by the lyrics view and the
/// Lyrics Options sheet.
class LyricsDisplay {
  LyricsDisplay._();

  static const String _key = 'peerm_lyrics_text_color';
  static const String _keepScreenOnKey = 'peerm_lyrics_keep_screen_on';
  static const String _wordGlowKey = 'peerm_lyrics_word_glow';
  static const String _glowDelayKey = 'peerm_lyrics_glow_delay_ms';

  /// How far the word glow is held back (positive) or pulled forward
  /// (negative), in milliseconds, for songs where it runs off from the voice.
  /// Only the glow moves; the line changes stay where the lyrics put them.
  static final ValueNotifier<int> glowDelayMs = ValueNotifier<int>(0);
  static const int glowDelayLimitMs = 500;

  /// Updates and persists [glowDelayMs] (kept within +-[glowDelayLimitMs]).
  static Future<void> setGlowDelayMs(int value) async {
    final v = value.clamp(-glowDelayLimitMs, glowDelayLimitMs);
    if (glowDelayMs.value == v) return;
    glowDelayMs.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_glowDelayKey, v);
  }

  /// How the current line lights up; see [WordGlowMode].
  static final ValueNotifier<WordGlowMode> wordGlow =
      ValueNotifier<WordGlowMode>(WordGlowMode.estimated);

  /// Updates and persists [wordGlow].
  static Future<void> setWordGlow(WordGlowMode value) async {
    if (wordGlow.value == value) return;
    wordGlow.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_wordGlowKey, value.name);
  }

  /// Current mode. Widgets listen to this and rebuild when it changes.
  static final ValueNotifier<LyricsColorMode> mode =
      ValueNotifier<LyricsColorMode>(LyricsColorMode.auto);

  /// Keep the screen awake while the player shows lyrics or the visualizer.
  static final ValueNotifier<bool> keepScreenOn = ValueNotifier<bool>(true);

  /// Loads the persisted preferences. Called once during bootstrap.
  static Future<void> init(SharedPreferences prefs) async {
    final raw = prefs.getString(_key);
    mode.value = LyricsColorMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => LyricsColorMode.auto,
    );
    keepScreenOn.value = prefs.getBool(_keepScreenOnKey) ?? true;
    glowDelayMs.value = (prefs.getInt(_glowDelayKey) ?? 0).clamp(
      -glowDelayLimitMs,
      glowDelayLimitMs,
    );
    final glow = prefs.getString(_wordGlowKey);
    wordGlow.value = WordGlowMode.values.firstWhere(
      (m) => m.name == glow,
      orElse: () => WordGlowMode.estimated,
    );
  }

  /// Updates and persists [keepScreenOn].
  static Future<void> setKeepScreenOn(bool value) async {
    if (keepScreenOn.value == value) return;
    keepScreenOn.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepScreenOnKey, value);
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
