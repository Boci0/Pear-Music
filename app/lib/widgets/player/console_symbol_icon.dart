import 'package:flutter/material.dart';

/// Clean, borderless prompt symbol (>_) for the diagnostics console.
class ConsoleSymbolIcon extends StatelessWidget {
  final double size;
  final Color? color;

  const ConsoleSymbolIcon({
    super.key,
    this.size = 18.0,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = color ?? IconTheme.of(context).color ?? Colors.white;
    return SizedBox(
      width: size * 1.15,
      height: size,
      child: CustomPaint(
        painter: _ConsoleSymbolPainter(color: iconColor),
      ),
    );
  }
}

class _ConsoleSymbolPainter extends CustomPainter {
  final Color color;
  const _ConsoleSymbolPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final promptPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = (h * 0.12).clamp(1.5, 2.4)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Draw '>' prompt
    final path = Path()
      ..moveTo(w * 0.08, h * 0.20)
      ..lineTo(w * 0.44, h * 0.50)
      ..lineTo(w * 0.08, h * 0.80);
    canvas.drawPath(path, promptPaint);

    // Draw '_' cursor
    final cursorPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = (h * 0.13).clamp(1.6, 2.5)
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
      Offset(w * 0.52, h * 0.80),
      Offset(w * 0.92, h * 0.80),
      cursorPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ConsoleSymbolPainter oldDelegate) =>
      oldDelegate.color != color;
}