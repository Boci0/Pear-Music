import 'package:flutter/material.dart';

/// Docks a screen to the rail inside a max-width column on wide windows, so
/// every tab's header and content share one left edge instead of starting at
/// a different x per tab width.
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
    // Docked to the rail instead of centered: every tab's header and content
    // then start at the same edge. Centering made each tab (with its own
    // maxWidth) start at a different x, so the header visibly jumped when
    // switching tabs. At phone widths the constraint is larger than the
    // viewport, so this stays a no-op there.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
