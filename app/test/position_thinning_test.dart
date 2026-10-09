import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/position_thinning.dart';

/// Guards the thinned position stream behind the status bar time, the Now
/// Playing pane's progress line and the mini player's fill. The engine reports
/// position about 15 times a second while playing; passing all of that on
/// redrew the window that often and kept the GPU busy (about 11 % on a
/// maximized window).
void main() {
  Future<List<Duration>> run(List<Duration> input) async {
    final source = StreamController<Duration>.broadcast();
    final seen = <Duration>[];
    final sub = thinPositions(source.stream).listen(seen.add);
    for (final d in input) {
      source.add(d);
    }
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    await source.close();
    return seen;
  }

  Duration ms(int v) => Duration(milliseconds: v);

  test('playback at 15 updates a second comes out at about 4', () async {
    // Ten seconds of playback reported every ~66 ms.
    final input = [for (var t = 0; t <= 10000; t += 66) ms(t)];
    final out = await run(input);
    expect(input.length, greaterThan(150));
    expect(out.length, inInclusiveRange(38, 42));
    for (var i = 1; i < out.length; i++) {
      expect(out[i] - out[i - 1], greaterThanOrEqualTo(ms(250)));
    }
  });

  test('seeks and new songs come through at once', () async {
    final out = await run([ms(10000), ms(10066), ms(42000), ms(41900), ms(0)]);
    expect(out, [ms(10000), ms(42000), ms(41900), ms(0)]);
  });

  test('a paused player repeating its position is silent', () async {
    final out = await run([for (var i = 0; i < 20; i++) ms(5000)]);
    expect(out, [ms(5000)]);
  });

  test('a new listener after all left starts fresh', () async {
    final source = StreamController<Duration>.broadcast();
    final thinned = thinPositions(source.stream);
    final first = <Duration>[];
    final a = thinned.listen(first.add);
    source.add(ms(1000));
    await Future<void>.delayed(Duration.zero);
    await a.cancel();

    final second = <Duration>[];
    final b = thinned.listen(second.add);
    source.add(ms(1100));
    await Future<void>.delayed(Duration.zero);
    await b.cancel();
    await source.close();

    expect(first, [ms(1000)]);
    expect(second, [ms(1100)]);
  });
}
