import 'dart:ui';

/// A smooth curve through [points], left to right (Catmull-Rom segments written
/// as cubic Beziers, so it passes through every point without kinks).
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
    final c1 = p1 + (p2 - p0) / 6;
    final c2 = p2 - (p3 - p1) / 6;
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
