import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/theme/glass.dart';
import 'package:peerm_app/widgets/pear_popup.dart';

Widget _host() => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showPearPopup<void>(
                context: context,
                builder: (ctx) => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Popup body'),
                ),
              ),
              child: const Text('Open popup'),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets(
    'desktop shows a centered dialog instead of a bottom sheet',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.tap(find.text('Open popup'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Popup body'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'phone keeps the pull-up bottom sheet',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.tap(find.text('Open popup'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Popup body'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'phone drag handle sits inside the glass panel, not above it',
    (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showPearPopup<void>(
                  context: context,
                  showDragHandle: true,
                  builder: (ctx) => const Text('Popup body'),
                ),
                child: const Text('Open popup'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Open popup'));
      await tester.pumpAndSettle();

      // Flutter's own handle would push the glass down and float above it.
      final sheetTop = tester.getTopLeft(find.byType(BottomSheet)).dy;
      final glassTop = tester.getTopLeft(find.byType(PearGlass)).dy;
      expect(glassTop, sheetTop);
      expect(
        find.descendant(
          of: find.byType(PearGlass),
          matching: find.byKey(const ValueKey('pear_sheet_handle')),
        ),
        findsOneWidget,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
