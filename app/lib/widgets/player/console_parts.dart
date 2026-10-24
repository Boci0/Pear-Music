import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The desktop player's read-outs: monospaced figures and small labels for
/// the volume and the queue.
class PearConsole {
  PearConsole._();

  static bool get on =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Monospaced figures for times and counters.
  static TextStyle readout({double size = 13, Color? color}) => TextStyle(
        fontFamily: 'Consolas',
        fontFamilyFallback: const ['Cascadia Mono', 'Courier New', 'monospace'],
        fontSize: size,
        height: 1.1,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: color,
      );

  /// Spaced capitals for labels (VOL, NOW PLAYING).
  static TextStyle label({Color? color}) => TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.6,
        color: color ?? Colors.white.withValues(alpha: 0.5),
      );

  static Color get rule => Colors.white.withValues(alpha: 0.14);

  static String clock(Duration d) {
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }
}
