import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Graphite is the only look now: a Style picked before (Glass, Frosted,
/// Solid) is dropped on start instead of lingering in the settings file.
void main() {
  for (final old in ['glass', 'frosted', 'solid', 'graphite']) {
    test('a saved "$old" style is cleared', () async {
      SharedPreferences.setMockInitialValues({'peerm_style': old});
      final prefs = await SharedPreferences.getInstance();
      IdentityService(prefs);
      expect(prefs.containsKey('peerm_style'), isFalse);
    });
  }
}
