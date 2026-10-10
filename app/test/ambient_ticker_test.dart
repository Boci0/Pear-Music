import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/ambient_ticker.dart';

void main() {
  testWidgets('listeners run at the rate they ask for and get the time it covers',
      (tester) async {
    final ticker = AmbientTicker.instance;
    final everyBeat = <Duration>[];
    final everyOther = <Duration>[];
    void fast(Duration s) => everyBeat.add(s);
    void slow(Duration s) => everyOther.add(s);

    ticker.addListener(fast);
    ticker.addListener(slow, every: 2);

    // Ten beats of the clock.
    await tester.pump(AmbientTicker.step * 10 + const Duration(milliseconds: 5));
    expect(everyBeat.length, 10);
    expect(everyOther.length, 5);
    expect(everyBeat.every((d) => d == AmbientTicker.step), isTrue);
    expect(everyOther.every((d) => d == AmbientTicker.step * 2), isTrue);

    // Same real time covered either way, so a loop advanced by the step it is
    // given keeps its speed.
    final total = everyBeat.fold<Duration>(Duration.zero, (a, b) => a + b);
    final totalSlow = everyOther.fold<Duration>(Duration.zero, (a, b) => a + b);
    expect(totalSlow, total);

    // Done inside the test: a timer left running fails the run.
    ticker.removeListener(fast);
    ticker.removeListener(slow);
  });

  testWidgets('the clock stops when the last listener leaves', (tester) async {
    final ticker = AmbientTicker.instance;
    var calls = 0;
    void l(Duration _) => calls++;
    ticker.addListener(l);
    await tester.pump(AmbientTicker.step * 3 + const Duration(milliseconds: 5));
    ticker.removeListener(l);
    final seen = calls;
    await tester.pump(AmbientTicker.step * 5);
    expect(calls, seen);
  });
}
