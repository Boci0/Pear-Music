import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/theme/glass.dart';
import 'package:peerm_app/theme/pear_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the grain tile ships as a small asset', () async {
    final data = await rootBundle.load(pearGrainAsset);
    expect(data.lengthInBytes, lessThan(40 * 1024));
  });

  test(
    'glass panels carry the grain at the style strength, flat ones do not',
    () {
      final scheme = ThemeData.dark().colorScheme;
      for (final style in PearStyle.values) {
        PearStyles.current.value = style;
        final glass = PearGlass.fill(scheme, reduced: false, grainScale: 2);
        expect(glass.image?.opacity, PearStyles.spec.grainAlpha);
        expect(glass.image?.scale, 2);
        expect(PearGlass.fill(scheme, reduced: true).image, isNull);
      }
      PearStyles.current.value = PearStyle.glass;
    },
  );
}
