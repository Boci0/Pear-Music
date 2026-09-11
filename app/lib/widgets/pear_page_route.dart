import 'package:flutter/material.dart';

/// Snappy, zero-lag route transition for drill-down navigation.
///
/// Uses an immediate 180ms forward / 150ms reverse fade with paired quadratic
/// curves (easeOutQuad on forward, easeInQuad on reverse). This eliminates the
/// visual stalling where reverse cubic transitions linger near 100% opacity.
class PearPageRoute<T> extends PageRoute<T> {
  final WidgetBuilder builder;

  PearPageRoute({
    required this.builder,
    super.settings,
    this.transitionDuration = const Duration(milliseconds: 180),
    this.reverseTransitionDuration = const Duration(milliseconds: 150),
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
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutQuad,
        reverseCurve: Curves.easeInQuad,
      ),
      child: child,
    );
  }
}
