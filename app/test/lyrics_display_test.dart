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
}
