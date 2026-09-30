import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/lyrics_display.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LyricsDisplay.mode.value = LyricsColorMode.auto;
  });

  test('auto follows the artwork preference', () {
    expect(
      LyricsDisplay.resolveDarkText(
        mode: LyricsColorMode.auto,
        artworkPrefersDarkText: true,
      ),
      isTrue,
    );
    expect(
      LyricsDisplay.resolveDarkText(
        mode: LyricsColorMode.auto,
        artworkPrefersDarkText: false,
      ),
      isFalse,
    );
  });

  test('forced modes ignore the artwork', () {
    expect(
      LyricsDisplay.resolveDarkText(
        mode: LyricsColorMode.light,
        artworkPrefersDarkText: true,
      ),
      isFalse,
    );
    expect(
      LyricsDisplay.resolveDarkText(
        mode: LyricsColorMode.dark,
        artworkPrefersDarkText: false,
      ),
      isTrue,
    );
  });

  test('set persists the choice and init restores it', () async {
    final prefs = await SharedPreferences.getInstance();
    await LyricsDisplay.set(LyricsColorMode.dark);
    expect(LyricsDisplay.mode.value, LyricsColorMode.dark);

    // Simulate a fresh launch.
    LyricsDisplay.mode.value = LyricsColorMode.auto;
    await LyricsDisplay.init(prefs);
    expect(LyricsDisplay.mode.value, LyricsColorMode.dark);
  });

  test('word glow defaults to word by word and remembers the choice',
      () async {
    SharedPreferences.setMockInitialValues({});
    await LyricsDisplay.init(await SharedPreferences.getInstance());
    expect(LyricsDisplay.wordGlow.value, WordGlowMode.estimated);

    await LyricsDisplay.setWordGlow(WordGlowMode.off);
    LyricsDisplay.wordGlow.value = WordGlowMode.estimated;
    await LyricsDisplay.init(await SharedPreferences.getInstance());
    expect(LyricsDisplay.wordGlow.value, WordGlowMode.off);
    await LyricsDisplay.setWordGlow(WordGlowMode.estimated);
  });

  test('the old "Exact only" setting loads as word by word', () async {
    SharedPreferences.setMockInitialValues({'peerm_lyrics_word_glow': 'exact'});
    await LyricsDisplay.init(await SharedPreferences.getInstance());
    expect(LyricsDisplay.wordGlow.value, WordGlowMode.estimated);
  });

  test('keep screen on defaults to on and remembers being turned off', () async {
    SharedPreferences.setMockInitialValues({});
    await LyricsDisplay.init(await SharedPreferences.getInstance());
    expect(LyricsDisplay.keepScreenOn.value, isTrue);

    await LyricsDisplay.setKeepScreenOn(false);
    await LyricsDisplay.init(await SharedPreferences.getInstance());
    expect(LyricsDisplay.keepScreenOn.value, isFalse);
  });
}
