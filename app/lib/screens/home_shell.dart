import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../services/artwork_palette.dart';
import '../services/lyrics_service.dart';
import '../services/player_theme.dart';
import '../services/session_diagnostics.dart';
import '../widgets/pear_page_route.dart';
import '../widgets/player_bar.dart';
import '../widgets/tactile_button.dart';
import 'explore_screen.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'playlists_screen.dart';
import 'settings_screen.dart';

/// Root shell with unified mobile-first layout (bottom navigation bar + mini player).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  AppLifecycleListener? _lifecycleListener;
  final GlobalKey<NavigatorState> _playlistsNavKey = GlobalKey<NavigatorState>();

  List<Widget> get _screens => [
    const HomeScreen(),
    Navigator(
      key: _playlistsNavKey,
      onGenerateRoute: (settings) => PearPageRoute(
        builder: (_) => const PlaylistsScreen(),
      ),
    ),
    ExploreScreen(isActive: _index == 2),
    const HistoryScreen(),
    const SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    SessionDiagnostics.init();
    const MethodChannel('com.peerm.peerm_app/memory')
        .setMethodCallHandler((call) async {
      if (call.method == 'onTrimMemory') {
        ArtworkPalette.compactMemory();
        LyricsService.compactMemory();
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      }
    });
    // Cap the in-memory image cache to a balanced budget so memory is bounded
    // while preventing covers and list tiles from flashing or reloading.
    PaintingBinding.instance.imageCache.maximumSize = 100;
    PaintingBinding.instance.imageCache.maximumSizeBytes = 25 * 1024 * 1024;
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) {
        SessionDiagnostics.onLifecycleChanged(state);
        if (state == AppLifecycleState.resumed) {
          // Restore the artwork-derived theme after a background/foreground
          // cycle so the UI doesn't sit on the fallback colour.
          context.read<PlayerTheme>().reapply();
        } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
          // Free unused decoded byte caches and live image entries to drop background memory footprint.
          ArtworkPalette.compactMemory();
          LyricsService.compactMemory();
          PaintingBinding.instance.imageCache.clearLiveImages();
        }
      },
    );
    _requestPermissions();
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    if (!mounted) return;
    try {
      final status = await Permission.notification.status;
      if (status.isDenied) {
        await Permission.notification.request();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _index == 0 && !(_playlistsNavKey.currentState?.canPop() ?? false),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_index == 1 && (_playlistsNavKey.currentState?.canPop() ?? false)) {
          _playlistsNavKey.currentState!.pop();
        } else if (_index != 0) {
          setState(() => _index = 0);
        }
      },
      child: Scaffold(
        extendBody: true,
        body: IndexedStack(
          index: _index,
          children: _screens,
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PlayerBar(),
              _MinimalistNavBar(
                selectedIndex: _index,
                onDestinationSelected: (i) {
                  if (i == 1 && _index == 1) {
                    _playlistsNavKey.currentState?.popUntil((route) => route.isFirst);
                  }
                  setState(() => _index = i);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MinimalistNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  const _MinimalistNavBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  /// Bar height. The icon row and label row are fixed heights, so this only
  /// has to hold them plus the bar's own padding.
  static const double barHeight = 64;

  /// Gap between an item's bounds and the rounded hover fill.
  static const double itemInsetX = 2;
  static const double itemInsetY = 4;

  /// Selected indicator: a capsule behind the icon alone. Sizing it from the
  /// icon instead of the label is what keeps the shape stable at any tab count,
  /// where a pill that had to wrap "Playlists" could only ever be as wide as a
  /// narrow item allows.
  static const double indicatorWidth = 48;
  static const double indicatorHeight = 30;

  /// Fixed row heights, so the indicator can be positioned exactly over the icon
  /// row without measuring text.
  static const double _iconRowHeight = indicatorHeight;
  static const double _labelRowHeight = 13;
  static const double _rowGap = 3;
  static const double _contentHeight =
      _iconRowHeight + _rowGap + _labelRowHeight;

  /// Outline width of the bar and of an item's hover fill. Both inset their
  /// content by this much, so the indicator has to account for it.
  static const double _barBorder = 1;

  /// Top of the icon row inside the bar's inner box, derived from the very same
  /// numbers the item lays its content out with (margins, border, centring), so
  /// the two cannot drift apart.
  static double _indicatorTopFor(double barInnerHeight) {
    final itemInner =
        barInnerHeight - itemInsetY * 2 - _barBorder * 2;
    return itemInsetY + _barBorder + (itemInner - _contentHeight) / 2;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      key: const ValueKey('nav_bar'),
      margin: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      height: barHeight,
      decoration: BoxDecoration(
        color: const Color(0xFF151518),
        borderRadius: BorderRadius.circular(barHeight / 2),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: _barBorder,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(barHeight / 2),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = constraints.maxWidth / 5;
            final indicatorWidthForItem =
                indicatorWidth.clamp(0.0, itemWidth - 16);
            return Stack(
              children: [
                // Gliding indicator, centred on the selected item's icon.
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  left: selectedIndex * itemWidth +
                      (itemWidth - indicatorWidthForItem) / 2,
                  top: _indicatorTopFor(constraints.maxHeight),
                  height: indicatorHeight,
                  width: indicatorWidthForItem,
                  child: Container(
                    key: const ValueKey('nav_indicator'),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(indicatorHeight / 2),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.38),
                        width: 1,
                      ),
                    ),
                  ),
                ),
                // Navigation items
                Row(
                  children: [
                    _NavBarItem(
                      index: 0,
                      selectedIndex: selectedIndex,
                      label: 'Library',
                      inactiveIcon: Icons.library_music_outlined,
                      activeIcon: Icons.library_music_rounded,
                      onTap: () => onDestinationSelected(0),
                    ),
                    _NavBarItem(
                      index: 1,
                      selectedIndex: selectedIndex,
                      label: 'Playlists',
                      inactiveIcon: Icons.queue_music_outlined,
                      activeIcon: Icons.queue_music_rounded,
                      onTap: () => onDestinationSelected(1),
                    ),
                    _NavBarItem(
                      index: 2,
                      selectedIndex: selectedIndex,
                      label: 'Explore',
                      inactiveIcon: Icons.explore_outlined,
                      activeIcon: Icons.explore_rounded,
                      onTap: () => onDestinationSelected(2),
                    ),
                    _NavBarItem(
                      index: 3,
                      selectedIndex: selectedIndex,
                      label: 'History',
                      inactiveIcon: Icons.history_outlined,
                      activeIcon: Icons.history_rounded,
                      onTap: () => onDestinationSelected(3),
                    ),
                    _NavBarItem(
                      index: 4,
                      selectedIndex: selectedIndex,
                      label: 'Settings',
                      inactiveIcon: Icons.settings_outlined,
                      activeIcon: Icons.settings_rounded,
                      onTap: () => onDestinationSelected(4),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _NavBarItem extends StatefulWidget {
  final int index;
  final int selectedIndex;
  final String label;
  final IconData inactiveIcon;
  final IconData activeIcon;
  final VoidCallback onTap;

  const _NavBarItem({
    required this.index,
    required this.selectedIndex,
    required this.label,
    required this.inactiveIcon,
    required this.activeIcon,
    required this.onTap,
  });

  @override
  State<_NavBarItem> createState() => _NavBarItemState();
}

class _NavBarItemState extends State<_NavBarItem> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.index == widget.selectedIndex;
    final scheme = Theme.of(context).colorScheme;

    return Expanded(
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapUp: (_) {
            setState(() => _isPressed = false);
            TactileFeedback.click();
            widget.onTap();
          },
          onTapCancel: () => setState(() => _isPressed = false),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(
              horizontal: _MinimalistNavBar.itemInsetX,
              vertical: _MinimalistNavBar.itemInsetY,
            ),
            decoration: BoxDecoration(
              color: (!isSelected && _isHovered)
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: (!isSelected && _isHovered)
                    ? Colors.white.withValues(alpha: 0.12)
                    : Colors.transparent,
                width: _MinimalistNavBar._barBorder,
              ),
            ),
            child: Center(
              child: AnimatedScale(
                scale: _isPressed ? 0.90 : (_isHovered ? 1.05 : 1.0),
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Fixed-height icon row that the selected indicator is
                    // positioned over, so the two cannot drift apart.
                    SizedBox(
                      height: _MinimalistNavBar.indicatorHeight,
                      child: Center(
                        child: Icon(
                          isSelected ? widget.activeIcon : widget.inactiveIcon,
                          size: 22,
                          color: isSelected
                              ? scheme.primary
                              : _isHovered
                                  ? Colors.white.withValues(alpha: 0.85)
                                  : Colors.white.withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                    const SizedBox(height: _MinimalistNavBar._rowGap),
                    SizedBox(
                      height: _MinimalistNavBar._labelRowHeight,
                      child: Center(
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            fontSize: 10.5,
                            height: 1.0,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                            color: isSelected
                                ? scheme.primary
                                : _isHovered
                                    ? Colors.white.withValues(alpha: 0.85)
                                    : Colors.white.withValues(alpha: 0.45),
                            letterSpacing: -0.2,
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
      ),
    );
  }
}
