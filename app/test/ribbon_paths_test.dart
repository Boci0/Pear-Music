import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/widgets/player/ribbon_paths.dart';

void main() {
  group('ribbonPoints', () {
    test('spans the width with the padding either side', () {
      final p = ribbonPoints(
        List.filled(24, 0.5),
        width: 300,
        baseY: 200,
        maxHeight: 100,
        padding: 16,
      );
      expect(p, hasLength(24));
      expect(p.first.dx, 16);
      expect(p.last.dx, closeTo(284, 1e-9));
    });

    test('a level of 1 reaches the full height and 0 keeps a floor above the base',
        () {
      final p = ribbonPoints(
        [0.0, 1.0],
        width: 100,
        baseY: 50,
        maxHeight: 40,
        padding: 0,
        floor: 2,
      );
      expect(p[0].dy, 48, reason: 'silent: the floor above the baseline');
      expect(p[1].dy, 10, reason: 'full: baseY - maxHeight');
    });

    test('a scale of 0 flattens the ribbon (nothing playing)', () {
      final p = ribbonPoints(
        [0.2, 0.9, 0.6],
        width: 90,
        baseY: 30,
        maxHeight: 20,
        padding: 0,
        floor: 2,
        scale: 0,
      );
      expect(p.every((o) => o.dy == 28), isTrue);
    });

    test('levels outside 0..1 are held inside the band', () {
      final p = ribbonPoints([-1.0, 5.0],
          width: 100, baseY: 50, maxHeight: 40, padding: 0, floor: 2);
      expect(p[0].dy, 48);
      expect(p[1].dy, 10);
    });
  });

  group('ribbonCurve', () {
    final pts = ribbonPoints(
      [0.2, 0.9, 0.3, 0.8, 0.1],
      width: 200,
      baseY: 100,
      maxHeight: 60,
      padding: 10,
    );

    test('the filled shape closes down to the baseline', () {
      final b = ribbonCurve(pts, closeAtY: 100).getBounds();
      expect(b.bottom, 100);
      expect(b.left, 10);
      expect(b.right, closeTo(190, 1e-9));
    });

    test('the open crest stays within a small overshoot of its own points', () {
      final b = ribbonCurve(pts).getBounds();
      final minY = pts.map((o) => o.dy).reduce((a, c) => a < c ? a : c);
      final maxY = pts.map((o) => o.dy).reduce((a, c) => a > c ? a : c);
      expect(b.top, greaterThan(minY - 6));
      expect(b.bottom, lessThan(maxY + 6));
    });

    test('the curve never dips below a quiet bin or rises above a loud one', () {
      // Alternating floor and full levels is the worst case for overshoot.
      final spiky = ribbonPoints(
        [for (var i = 0; i < 24; i++) i.isEven ? 0.0 : 1.0],
        width: 240,
        baseY: 100,
        maxHeight: 60,
        padding: 0,
        floor: 2,
      );
      final b = ribbonCurve(spiky).getBounds();
      expect(b.bottom, lessThanOrEqualTo(100 - 2 + 1e-9),
          reason: 'not below the floor');
      expect(b.top, greaterThanOrEqualTo(100 - 60 - 1e-9),
          reason: 'not above the full-height line');
    });

    test('an empty or single point list gives an empty path without throwing', () {
      expect(ribbonCurve(const []).getBounds(), Rect.zero);
      expect(() => ribbonCurve(const [Offset(1, 2)]), returnsNormally);
    });
  });
}
