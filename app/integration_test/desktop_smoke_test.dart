import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:peerm_app/main.dart' as app;
import 'package:peerm_app/screens/home_screen.dart';
import 'package:peerm_app/screens/home_shell.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop window loads and navigates primary views', (tester) async {
    // Launch main app
    app.main();
    // Pump until asynchronous services initialize and HomeShell is mounted
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(HomeShell).evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();

    // Verify HomeShell renders
    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.byType(HomeScreen), findsOneWidget);

    // Verify sidebar or navigation icons
    final searchIconFinder = find.byIcon(Icons.search);
    if (searchIconFinder.evaluate().isNotEmpty) {
      await tester.tap(searchIconFinder.first);
      await tester.pumpAndSettle();

      // Enter search query
      final textFieldFinder = find.byType(TextField);
      if (textFieldFinder.evaluate().isNotEmpty) {
        await tester.enterText(textFieldFinder.first, 'Test Query');
        await tester.pumpAndSettle();
      }
    }

    // Verify scaffold and custom scroll view are active
    expect(find.byType(Scaffold), findsWidgets);
    expect(find.byType(CustomScrollView), findsWidgets);
  });
}
