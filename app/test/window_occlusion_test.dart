import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/window_occlusion.dart';

void main() {
  testWidgets('a covered window parks frames and a visible one resumes them', (
    tester,
  ) async {
    var covered = false;
    final watcher = WindowOcclusion.startForTest(() => covered);
    await tester.pumpWidget(const SizedBox());

    // One covered sample is not enough: a window dragged past is not parked.
    covered = true;
    await tester.pump(const Duration(seconds: 1));
    expect(WindowOcclusion.covered.value, isFalse);
    expect(SchedulerBinding.instance.framesEnabled, isTrue);

    await tester.pump(const Duration(seconds: 1));
    expect(WindowOcclusion.covered.value, isTrue);
    expect(SchedulerBinding.instance.framesEnabled, isFalse);

    // The first sample that sees the window brings frames back.
    covered = false;
    await tester.pump(const Duration(seconds: 1));
    expect(WindowOcclusion.covered.value, isFalse);
    expect(SchedulerBinding.instance.framesEnabled, isTrue);
    // The timer must be gone before the test ends.
    watcher.dispose();
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('input lifts the hold at once, whatever the samples say', (
    tester,
  ) async {
    final watcher = WindowOcclusion.startForTest(() => true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    expect(WindowOcclusion.covered.value, isTrue);

    GestureBinding.instance.pointerRouter.route(
      const PointerMoveEvent(position: Offset(5, 5)),
    );
    expect(WindowOcclusion.covered.value, isFalse);
    expect(SchedulerBinding.instance.framesEnabled, isTrue);

    // It takes two fresh covered samples to park again.
    await tester.pump(const Duration(seconds: 1));
    expect(WindowOcclusion.covered.value, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(WindowOcclusion.covered.value, isTrue);
    // The timer must be gone before the test ends.
    watcher.dispose();
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('a focus report while covered does not turn frames back on', (
    tester,
  ) async {
    final watcher = WindowOcclusion.startForTest(() => true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    expect(SchedulerBinding.instance.framesEnabled, isFalse);

    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.inactive,
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(SchedulerBinding.instance.framesEnabled, isFalse);
    // The timer must be gone before the test ends.
    watcher.dispose();
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
}
