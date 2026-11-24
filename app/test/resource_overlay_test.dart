import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/widgets/resource_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('IdentityService persists resourceOverlay setting', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    expect(identity.resourceOverlay, isFalse);

    await identity.setResourceOverlay(true);
    expect(identity.resourceOverlay, isTrue);

    final reloaded = IdentityService(prefs);
    expect(reloaded.resourceOverlay, isTrue);
  });

  testWidgets('ResourceOverlay renders FPS, RAM, and IMG without overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: ResourceOverlay(),
          ),
        ),
      ),
    );

    expect(find.textContaining('FPS '), findsOneWidget);
    expect(find.textContaining('RAM '), findsOneWidget);
    expect(find.textContaining('IMG '), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
