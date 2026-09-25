import 'package:flutter/material.dart';

import '../theme/glass.dart';
import 'pear_app_bar.dart';
import 'tactile_button.dart';

/// Desktop side rail: the five primary destinations as a vertical bar that
/// replaces the bottom navigation bar on wide windows (>= 900 logical px).
///
/// A frosted glass panel, like the bottom bar and the mini player card, so
/// all three read as the same family of shapes.
class SideRail extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  const SideRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  static const List<({String label, IconData icon, IconData activeIcon})>
      _items = [
    (
      label: 'Library',
      icon: Icons.library_music_outlined,
      activeIcon: Icons.library_music_rounded,
    ),
    (
      label: 'Playlists',
      icon: Icons.queue_music_outlined,
      activeIcon: Icons.queue_music_rounded,
    ),
    (
      label: 'Explore',
      icon: Icons.explore_outlined,
      activeIcon: Icons.explore_rounded,
    ),
    (
      label: 'History',
      icon: Icons.history_outlined,
      activeIcon: Icons.history_rounded,
    ),
    (
      label: 'Settings',
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
      child: SizedBox(
        key: const ValueKey('side_rail'),
        width: 86,
        child: PearGlass(
          borderRadius: BorderRadius.circular(PearGlassTokens.floatingRadius),
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 16, bottom: 6),
                child: PearMark(size: 30),
              ),
              Stack(
                children: [
                  // Gliding selection capsule, shared by all items so it
                  // slides between them (with a slight overshoot) like the
                  // phone nav bar's indicator instead of fading in place.
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 340),
                    curve: Curves.easeOutBack,
                    top: selectedIndex * _SideRailItem.height +
                        _SideRailItem.iconTop,
                    left: 0,
                    right: 0,
                    height: _SideRailItem.pillHeight,
                    child: Center(
                      child: Container(
                        key: const ValueKey('side_rail_indicator'),
                        width: _SideRailItem.pillWidth,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.24),
                          borderRadius: BorderRadius.circular(
                            _SideRailItem.pillHeight / 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Column(
                    children: [
                      for (var i = 0; i < _items.length; i++)
                        _SideRailItem(
                          index: i,
                          selectedIndex: selectedIndex,
                          label: _items[i].label,
                          icon: _items[i].icon,
                          activeIcon: _items[i].activeIcon,
                          onTap: () => onDestinationSelected(i),
                        ),
                    ],
                  ),
                ],
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _SideRailItem extends StatefulWidget {
  /// Row geometry, fixed so the rail's shared indicator can be positioned
  /// exactly over an item's icon without measuring anything.
  static const double height = 64;
  static const double pillWidth = 48;
  static const double pillHeight = 30;
  static const double _labelHeight = 14;
  static const double _gap = 3;
  static const double iconTop =
      (height - pillHeight - _gap - _labelHeight) / 2;

  final int index;
  final int selectedIndex;
  final String label;
  final IconData icon;
  final IconData activeIcon;
  final VoidCallback onTap;

  const _SideRailItem({
    required this.index,
    required this.selectedIndex,
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.onTap,
  });

  @override
  State<_SideRailItem> createState() => _SideRailItemState();
}

class _SideRailItemState extends State<_SideRailItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = widget.index == widget.selectedIndex;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_isHovered) setState(() => _isHovered = true);
      },
      onExit: (_) {
        if (_isHovered) setState(() => _isHovered = false);
      },
      child: TactileBounce(
        scaleDown: 0.94,
        onTap: widget.onTap,
        child: SizedBox(
          height: _SideRailItem.height,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // The selected fill is the rail's gliding indicator; the item
              // only draws its own capsule for hover.
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                width: _SideRailItem.pillWidth,
                height: _SideRailItem.pillHeight,
                decoration: BoxDecoration(
                  color: !isSelected && _isHovered
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(
                    _SideRailItem.pillHeight / 2,
                  ),
                ),
                child: Icon(
                  isSelected ? widget.activeIcon : widget.icon,
                  size: 22,
                  color:
                      isSelected ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: _SideRailItem._gap),
              SizedBox(
                height: _SideRailItem._labelHeight,
                child: Center(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.0,
                      letterSpacing: -0.4,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: isSelected
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
