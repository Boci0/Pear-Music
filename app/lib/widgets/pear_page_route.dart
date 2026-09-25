import 'package:flutter/material.dart';

/// Lively, low-cost route transition for drill-down navigation.
///
/// The new page fades in while rising a few pixels and settling from a hair
/// smaller than full size (easeOutCubic, 280ms), so it lands instead of just
/// appearing. The reverse is a quick 170ms fade on easeInQuad, which avoids
/// the stall where a reverse cubic lingers near full opacity. Fade, slide and
/// scale are all compositor transforms, so the motion costs no relayout.
class PearPageRoute<T> extends PageRoute<T> {
  final WidgetBuilder builder;

  PearPageRoute({
    required this.builder,
    super.settings,
    this.transitionDuration = const Duration(milliseconds: 280),
    this.reverseTransitionDuration = const Duration(milliseconds: 170),
  });

  @override
  final Duration transitionDuration;

  @override
  final Duration reverseTransitionDuration;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInQuad,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.025),
          end: Offset.zero,
        ).animate(curved),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
          child: child,
        ),
      ),
    );
  }
}
