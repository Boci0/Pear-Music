import 'package:flutter/material.dart';

import '../theme/glass.dart';
import 'pear_app_bar.dart';
import 'tactile_button.dart';

/// Desktop side rail: the five primary destinations as a vertical bar that
/// replaces the bottom navigation bar on wide windows (>= 900 logical px).
///
/// A frosted glass panel, like the bottom bar and the mini player card, so
/// all three read as the same family of shapes. The selected destination sits
/// in the same pill the bottom bar uses: icon and label together, soft corners,
/// the accent at one strength, the glass hairline for an edge.
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

  /// Width of the rail panel. Wide enough that the pill keeps the phone bar's
  /// proportions with air around it, instead of filling the panel edge to edge.
  static const double railWidth = 100;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
      child: SizedBox(
        key: const ValueKey('side_rail'),
        width: railWidth,
        child: PearGlass(
          borderRadius: BorderRadius.circular(PearGlassTokens.floatingRadius),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 10),
                child: Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: PearGlassTokens.cardSheen,
                    border: Border.all(color: PearGlassTokens.cardRim),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const PearMark(size: 26),
                ),
              ),
              Stack(
                children: [
                  // Gliding selection pill, shared by all items so it slides
                  // between them like the phone nav bar's pill instead of
                  // fading in place. No overshoot: on a long jump (Settings to
                  // Library) it would run past the list, behind the logo tile
                  // or below the last item, and be cut off by the Stack's edge.
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                    top:
                        selectedIndex * _SideRailItem.height +
                        _SideRailItem.pillTop,
                    left: 0,
                    right: 0,
                    height: _SideRailItem.pillHeight,
                    child: Center(
                      child: Container(
                        key: const ValueKey('side_rail_indicator'),
                        width: _SideRailItem.pillWidth,
                        decoration: PearGlassTokens.selectionPill(
                          scheme,
                          radius: _SideRailItem.pillRadius,
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
  /// Row geometry, fixed so the rail's shared pill can be positioned exactly
  /// over an item without measuring anything. The pill is 44 tall around a
  /// 35px icon-and-label block, and about 1.7 times wider than tall, the same
  /// shape as the bottom bar's. The rows leave 16px between pills.
  static const double height = 60;
  static const double pillHeight = 44;

  /// Gap between the pill and the rail's side edges.
  static const double pillInsetX = 12;
  static const double pillWidth = SideRail.railWidth - pillInsetX * 2;

  /// The same corner radius as the phone bar's pill.
  static const double pillRadius = PearGlassTokens.selectionPillRadius;

  static const double pillTop = (height - pillHeight) / 2;
  static const double iconSize = 20;
  static const double labelHeight = 12;
  static const double gap = 3;

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
    final color = isSelected ? scheme.primary : scheme.onSurfaceVariant;
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
          child: Center(
            // The selected fill is the rail's gliding pill; the item only
            // draws its own pill for hover, so a hovered item previews the
            // shape it would get.
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              width: _SideRailItem.pillWidth,
              height: _SideRailItem.pillHeight,
              decoration: BoxDecoration(
                color: !isSelected && _isHovered
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(_SideRailItem.pillRadius),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isSelected ? widget.activeIcon : widget.icon,
                    size: _SideRailItem.iconSize,
                    color: color,
                  ),
                  const SizedBox(height: _SideRailItem.gap),
                  SizedBox(
                    height: _SideRailItem.labelHeight,
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.0,
                            letterSpacing: -0.4,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: color,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
