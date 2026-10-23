import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/lyrics_display.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('lyric text size saves the sizes on offer and ignores others', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await LyricsDisplay.init(prefs);
    expect(LyricsDisplay.textScale.value, 1.0);

    await LyricsDisplay.setTextScale(LyricsDisplay.textSizes['XL']!);
    await LyricsDisplay.setTextScale(3.0);
    expect(LyricsDisplay.textScale.value, 1.4);

    // A fresh start reads the saved size back.
    LyricsDisplay.textScale.value = 1.0;
    await LyricsDisplay.init(prefs);
    expect(LyricsDisplay.textScale.value, 1.4);
  });

  test('an unknown saved size falls back to the default', () async {
    SharedPreferences.setMockInitialValues({'peerm_lyrics_text_scale': 2.5});
    await LyricsDisplay.init(await SharedPreferences.getInstance());
    expect(LyricsDisplay.textScale.value, 1.0);
  });
}
