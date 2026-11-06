import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/widgets/immersion_filter.dart';

void main() {
  test('every colour filter choice but Off has a filter', () {
    expect(ColorGrade.passes(ColorGrade.off), isEmpty);
    for (var i = 1; i < ColorGrade.labels.length; i++) {
      expect(ColorGrade.passes(i), isNotEmpty, reason: ColorGrade.labels[i]);
    }
  });
}
