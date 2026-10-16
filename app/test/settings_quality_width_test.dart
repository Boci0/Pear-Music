import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the quality choices span the padded row, so they sit centred', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1800);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<int>(
              expandedInsets: EdgeInsets.zero,
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text('Auto')),
                ButtonSegment(value: 360, label: Text('360p')),
                ButtonSegment(value: 480, label: Text('480p')),
                ButtonSegment(value: 720, label: Text('720p')),
                ButtonSegment(value: 1080, label: Text('1080p')),
              ],
              selected: const {1080},
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(SegmentedButton<int>));
    expect(rect.left, 16);
    expect(rect.right, 360 - 16);
  });
}
