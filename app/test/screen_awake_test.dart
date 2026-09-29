import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/screen_awake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the screen stays awake until the last holder lets go', () {
    final lyrics = Object();
    final pane = Object();

    ScreenAwake.hold(lyrics, true);
    ScreenAwake.hold(pane, true);
    expect(ScreenAwake.isOn, isTrue);

    ScreenAwake.hold(lyrics, false);
    expect(ScreenAwake.isOn, isTrue, reason: 'the pane still wants it');

    ScreenAwake.hold(pane, false);
    expect(ScreenAwake.isOn, isFalse);
  });

  test('letting go twice is harmless', () {
    final holder = Object();
    ScreenAwake.hold(holder, true);
    ScreenAwake.hold(holder, false);
    ScreenAwake.hold(holder, false);
    expect(ScreenAwake.isOn, isFalse);
  });
}
