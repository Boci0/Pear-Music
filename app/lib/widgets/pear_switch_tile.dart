import 'package:flutter/material.dart';

import '../theme/glass.dart';

/// A settings row with an on/off switch, drawn as a square toggle (a block
/// that slides along a framed track).
class PearSwitchTile extends StatelessWidget {
  const PearSwitchTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.secondary,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? title;
  final Widget? subtitle;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return MergeSemantics(
      child: ListTile(
        leading: secondary,
        title: title,
        subtitle: subtitle,
        enabled: enabled,
        onTap: enabled ? () => onChanged!(!value) : null,
        trailing: _SquareToggle(value: value, enabled: enabled),
      ),
    );
  }
}

class _SquareToggle extends StatelessWidget {
  const _SquareToggle({required this.value, required this.enabled});

  final bool value;
  final bool enabled;

  static const double _width = 40;
  static const double _height = 20;
  static const double _block = 14;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final on = value && enabled;
    return Semantics(
      toggled: value,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          width: _width,
          height: _height,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: on
                ? accent.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.04),
            border: Border.all(
              color: on
                  ? accent
                  : Colors.white.withValues(alpha: PearGlassTokens.edge * 2),
            ),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            alignment: on ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: _block,
              height: _block,
              color: on ? accent : Colors.white.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }
}
