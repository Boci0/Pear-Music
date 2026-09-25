import 'package:flutter/material.dart';

import 'tactile_button.dart';

/// Rounded filter/toggle pill shared by the Library filters and the Explore
/// genres: a faint glass fill at rest, a brighter one on hover, and the
/// accent tint (with a soft accent glow) when selected.
class FilterPill extends StatefulWidget {
  final String? label;
  final IconData? icon;
  final String? tooltip;
  final bool isSelected;
  final VoidCallback onTap;

  const FilterPill({
    super.key,
    this.label,
    this.icon,
    this.tooltip,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<FilterPill> createState() => _FilterPillState();
}

class _FilterPillState extends State<FilterPill> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    final bgColor = widget.isSelected
        ? primary.withValues(alpha: _isHovered ? 0.28 : 0.20)
        : (_isHovered
              ? Colors.white.withValues(alpha: 0.09)
              : Colors.white.withValues(alpha: 0.05));

    final textColor = widget.isSelected
        ? primary
        : theme.colorScheme.onSurfaceVariant.withValues(
            alpha: _isHovered ? 1.0 : 0.9,
          );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_isHovered) setState(() => _isHovered = true);
      },
      onExit: (_) {
        if (_isHovered) setState(() => _isHovered = false);
      },
      child: TactileBounce(
        scaleDown: 0.95,
        duration: const Duration(milliseconds: 80),
        onTap: widget.onTap,
        tooltip: widget.tooltip,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutQuad,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(20),
            boxShadow: widget.isSelected
                ? [
                    BoxShadow(
                      color: primary.withValues(alpha: 0.22),
                      blurRadius: 14,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 15, color: textColor),
                const SizedBox(width: 6),
              ],
              if (widget.label != null)
                Text(
                  widget.label!,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontSize: 13,
                    fontWeight: widget.isSelected
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: textColor,
                    letterSpacing: -0.1,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
