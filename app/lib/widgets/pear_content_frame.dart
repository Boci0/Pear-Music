import 'package:flutter/material.dart';

/// Centers a screen inside a max-width column on wide windows so every tab
/// scales past the phone width instead of stretching edge to edge.
///
/// On phone widths the constraint is larger than the viewport, so this is a
/// no-op there and the phone layout is untouched.
class PearContentFrame extends StatelessWidget {
  final double maxWidth;
  final Widget child;

  const PearContentFrame({
    super.key,
    required this.maxWidth,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
