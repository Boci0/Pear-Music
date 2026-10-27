import 'package:flutter/material.dart';

import 'pear_backdrop.dart';

/// Lively, low-cost route transition for drill-down navigation.
///
/// Screens are see-through (the app backdrop is painted once, behind every
/// route), so a plain fade would show the old page's content through the new
/// one. The route therefore brings its own backdrop copy, which fades in over
/// the first third of the motion and hides the old page quickly. The page
/// content then fades in while rising a few pixels and settling from a hair
/// smaller than full size (easeOutCubic, 280ms). On the way back the content
/// leaves first and the backdrop last, on quick easeInQuad curves (170ms), so
/// the two pages never overlap.
///
/// Fade, slide and scale are compositor transforms, so the motion costs no
/// relayout.
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
    final cover = CurvedAnimation(
      parent: animation,
      curve: const Interval(0, 0.35, curve: Curves.easeOut),
      reverseCurve: const Interval(0, 0.45, curve: Curves.easeIn),
    );
    final content = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.1, 1, curve: Curves.easeOutCubic),
      reverseCurve: const Interval(0.3, 1, curve: Curves.easeInQuad),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        // Only needed while the old page could show through; once the route
        // has settled the app-wide backdrop underneath is identical.
        AnimatedBuilder(
          animation: animation,
          builder: (context, backdrop) => animation.isCompleted
              ? const SizedBox.shrink()
              : FadeTransition(opacity: cover, child: backdrop),
          child: const IgnorePointer(child: PearBackdrop()),
        ),
        FadeTransition(
          opacity: content,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.025),
              end: Offset.zero,
            ).animate(content),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.97, end: 1).animate(content),
              child: _StillWhileLeaving(animation: animation, child: child),
            ),
          ),
        ),
      ],
    );
  }
}

/// A leaving page is drawn as a still picture of itself: a playing video or
/// the blurred lyrics backdrop would otherwise be redrawn under the fade on
/// every frame of the close, which stuttered on phones.
class _StillWhileLeaving extends StatefulWidget {
  final Animation<double> animation;
  final Widget child;

  const _StillWhileLeaving({required this.animation, required this.child});

  @override
  State<_StillWhileLeaving> createState() => _StillWhileLeavingState();
}

class _StillWhileLeavingState extends State<_StillWhileLeaving> {
  final _snapshot = SnapshotController();

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(_StillWhileLeaving oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation == widget.animation) return;
    oldWidget.animation.removeStatusListener(_onStatus);
    widget.animation.addStatusListener(_onStatus);
  }

  // A cancelled close (back swipe let go) goes forward again: live once more.
  void _onStatus(AnimationStatus status) =>
      _snapshot.allowSnapshotting = status == AnimationStatus.reverse;

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    _snapshot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SnapshotWidget(
    controller: _snapshot,
    // A platform view cannot be captured; such a page just leaves live.
    mode: SnapshotMode.permissive,
    child: widget.child,
  );
}
