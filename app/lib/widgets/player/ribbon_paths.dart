import 'dart:ui';

/// A smooth curve through [points], left to right (Catmull-Rom segments written
/// as cubic Beziers, with the vertical control points held inside each
/// segment's range so it never overshoots its own points).
///
/// With [closeAtY] the curve is closed down to that baseline, giving the
/// filled shape under it; without, it is the open crest line.
Path ribbonCurve(List<Offset> points, {double? closeAtY}) {
  final path = Path();
  if (points.isEmpty) return path;
  if (closeAtY != null) {
    path
      ..moveTo(points.first.dx, closeAtY)
      ..lineTo(points.first.dx, points.first.dy);
  } else {
    path.moveTo(points.first.dx, points.first.dy);
  }
  for (var i = 0; i < points.length - 1; i++) {
    final p0 = i == 0 ? points[0] : points[i - 1];
    final p1 = points[i];
    final p2 = points[i + 1];
    final p3 = i + 2 < points.length ? points[i + 2] : points[i + 1];
    // Control points are held to the vertical range of their segment so the
    // curve never dips below a quiet bin or rises above a loud one: plain
    // Catmull-Rom overshoots there, which sliced the crest flat against the
    // baseline and poked above the band on transients.
    final lo = p1.dy < p2.dy ? p1.dy : p2.dy;
    final hi = p1.dy < p2.dy ? p2.dy : p1.dy;
    final c1 = Offset(
      p1.dx + (p2.dx - p0.dx) / 6,
      (p1.dy + (p2.dy - p0.dy) / 6).clamp(lo, hi).toDouble(),
    );
    final c2 = Offset(
      p2.dx - (p3.dx - p1.dx) / 6,
      (p2.dy - (p3.dy - p1.dy) / 6).clamp(lo, hi).toDouble(),
    );
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
  }
  if (closeAtY != null) {
    path
      ..lineTo(points.last.dx, closeAtY)
      ..close();
  }
  return path;
}

/// Points for a ribbon across [width], one per level, [padding] in from each
/// edge. A level of 1.0 reaches [maxHeight] above [baseY]; every point sits at
/// least [floor] above it so the line never sinks into the baseline.
List<Offset> ribbonPoints(
  List<double> levels, {
  required double width,
  required double baseY,
  required double maxHeight,
  double padding = 16.0,
  double floor = 2.0,
  double scale = 1.0,
}) {
  final n = levels.length;
  if (n == 0) return const [];
  final step = n == 1 ? 0.0 : (width - padding * 2) / (n - 1);
  return [
    for (var i = 0; i < n; i++)
      Offset(
        padding + i * step,
        baseY - (floor + (maxHeight - floor) * levels[i].clamp(0.0, 1.0) * scale),
      ),
  ];
}
