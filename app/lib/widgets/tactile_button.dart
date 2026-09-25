import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';

/// Centralized tactile feedback (sound click + haptics) utility.
class TactileFeedback {
  /// Emits a subtle physical click sound and light haptic impact.
  static void click() {
    SystemSound.play(SystemSoundType.click);
    HapticFeedback.lightImpact();
  }

  /// Emits a subtle selection tick for toggles and sliders.
  static void selection() {
    HapticFeedback.selectionClick();
  }
}

/// A responsive, spring-physics tactile wrapper: it dips quickly on touch, then
/// springs back with a small overshoot on release, and triggers crisp
/// audio/haptic feedback. With Reduced Effects on, the release settles without
/// the overshoot.
class TactileBounce extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scaleDown;
  final bool feedback;
  final Duration duration;
  final HitTestBehavior behavior;
  final BorderRadius? borderRadius;
  final String? tooltip;

  const TactileBounce({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scaleDown = 0.94,
    this.feedback = true,
    this.duration = const Duration(milliseconds: 100),
    this.behavior = HitTestBehavior.opaque,
    this.borderRadius,
    this.tooltip,
  });

  @override
  State<TactileBounce> createState() => _TactileBounceState();
}

class _TactileBounceState extends State<TactileBounce>
    with SingleTickerProviderStateMixin {
  /// Press depth: 0 at rest, 1 fully pressed. Unbounded so the release spring
  /// can overshoot past rest, which briefly scales the child above 1.
  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
  );

  bool _isPressed = false;

  /// A quick tap can release before the dip is visible; the release waits for
  /// at least this much depth so every tap reads as a press.
  static const double _minDepth = 0.7;

  static final SpringDescription _bouncy = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 520,
    ratio: 0.45,
  );
  static final SpringDescription _calm = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 520,
    ratio: 1,
  );

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    if (widget.onTap == null && widget.onLongPress == null) return;
    _isPressed = true;
    _press.animateTo(1, duration: widget.duration, curve: Curves.easeOutCubic);
  }

  void _onTapUp(TapUpDetails _) => _release();

  void _onTapCancel() => _release();

  Future<void> _release() async {
    if (!_isPressed) return;
    _isPressed = false;
    final reduced =
        context.read<AppController?>()?.identity.reducedEffects ?? false;
    if (_press.value < _minDepth) {
      await _press
          .animateTo(
            _minDepth,
            duration: const Duration(milliseconds: 60),
            curve: Curves.easeOut,
          )
          .orCancel
          .catchError((_) {});
      if (!mounted || _isPressed) return;
    }
    _press.animateWith(
      SpringSimulation(reduced ? _calm : _bouncy, _press.value, 0, 0),
    );
  }

  void _handleTap() {
    if (widget.onTap == null) return;
    if (widget.feedback) {
      TactileFeedback.click();
    }
    widget.onTap!();
  }

  void _handleLongPress() {
    if (widget.onLongPress == null) return;
    if (widget.feedback) {
      TactileFeedback.click();
    }
    widget.onLongPress!();
  }

  @override
  Widget build(BuildContext context) {
    final depth = 1 - widget.scaleDown;
    Widget content = AnimatedBuilder(
      animation: _press,
      builder: (context, child) => Transform.scale(
        scale: 1 - depth * _press.value,
        child: child,
      ),
      child: widget.child,
    );

    if (widget.tooltip != null) {
      content = Tooltip(
        message: widget.tooltip!,
        child: content,
      );
    }

    if (widget.onTap == null && widget.onLongPress == null) {
      return content;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: widget.behavior,
        onTapDown: _onTapDown,
        onTapUp: _onTapUp,
        onTapCancel: _onTapCancel,
        onTap: _handleTap,
        onLongPress: widget.onLongPress != null ? _handleLongPress : null,
        child: content,
      ),
    );
  }
}

/// Tactile drop-in replacement for IconButton that scales down on press
/// and triggers physical click feedback.
class TactileIconButton extends StatelessWidget {
  final Widget icon;
  final VoidCallback? onPressed;
  final double? iconSize;
  final Color? color;
  final String? tooltip;
  final EdgeInsetsGeometry padding;
  final double scaleDown;
  final VisualDensity? visualDensity;
  final BoxConstraints? constraints;

  const TactileIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.iconSize,
    this.color,
    this.tooltip,
    this.padding = const EdgeInsets.all(8.0),
    this.scaleDown = 0.88,
    this.visualDensity,
    this.constraints,
  });

  @override
  Widget build(BuildContext context) {
    Widget content = Padding(
      padding: padding,
      child: IconTheme.merge(
        data: IconThemeData(
          size: iconSize ?? 24.0,
          color: color,
        ),
        child: icon,
      ),
    );

    if (constraints != null) {
      content = ConstrainedBox(
        constraints: constraints!,
        child: Center(child: content),
      );
    }

    return TactileBounce(
      onTap: onPressed,
      tooltip: tooltip,
      scaleDown: scaleDown,
      child: content,
    );
  }
}
