import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// A responsive, spring-physics tactile wrapper that smoothly depresses on touch
/// and triggers crisp audio/haptic feedback on release.
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

class _TactileBounceState extends State<TactileBounce> {
  bool _isPressed = false;

  void _onTapDown(TapDownDetails _) {
    if (widget.onTap == null && widget.onLongPress == null) return;
    setState(() => _isPressed = true);
  }

  void _onTapUp(TapUpDetails _) {
    if (_isPressed) {
      setState(() => _isPressed = false);
    }
  }

  void _onTapCancel() {
    if (_isPressed) {
      setState(() => _isPressed = false);
    }
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
    Widget content = AnimatedScale(
      scale: _isPressed ? widget.scaleDown : 1.0,
      duration: widget.duration,
      curve: Curves.easeOutCubic,
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
