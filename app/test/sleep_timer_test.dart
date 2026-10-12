import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/sleep_timer.dart';

void main() {
  const tick = Duration(milliseconds: 30);
  Future<void> wait(Duration d) => Future<void>.delayed(d);

  test('a countdown fires once and reports the time left', () async {
    var fired = 0;
    final timer = SleepTimer(onExpire: () async => fired++);
    timer.set(tick * 4);
    expect(timer.isActive, isTrue);
    expect(timer.remaining, isNotNull);
    expect(timer.remaining! <= tick * 4, isTrue);
    expect(fired, 0);

    await wait(tick * 8);
    expect(fired, 1);
  });

  test('setting a new timer replaces the running one', () async {
    var fired = 0;
    final timer = SleepTimer(onExpire: () async => fired++);
    timer.set(tick);
    timer.set(tick * 6);
    await wait(tick * 3);
    expect(fired, 0, reason: 'the first countdown was replaced');
    await wait(tick * 6);
    expect(fired, 1);
  });

  test('end of song and end of queue are flags, not countdowns', () async {
    var fired = 0;
    final timer = SleepTimer(onExpire: () async => fired++);
    timer.set(tick, endOfSong: true);
    expect(timer.isActive, isTrue);
    expect(timer.endOfSong, isTrue);
    expect(timer.remaining, isNull);
    await wait(tick * 3);
    expect(fired, 0);

    timer.set(null, endOfQueue: true);
    expect(timer.endOfSong, isFalse);
    expect(timer.endOfQueue, isTrue);
  });

  test('cancel clears everything and nothing fires', () async {
    var fired = 0;
    final timer = SleepTimer(onExpire: () async => fired++);
    timer.set(tick);
    timer.cancel();
    expect(timer.isActive, isFalse);
    expect(timer.remaining, isNull);
    await wait(tick * 3);
    expect(fired, 0);
  });
}
