import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
