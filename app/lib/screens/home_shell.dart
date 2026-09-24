import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../services/artwork_palette.dart';
import '../services/lyrics_service.dart';
import '../services/player_theme.dart';
import '../services/session_diagnostics.dart';
import '../widgets/pear_content_frame.dart';
import '../widgets/pear_page_route.dart';
import '../widgets/player_bar.dart';
import '../widgets/side_rail.dart';
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
  final GlobalKey<NavigatorState> _playlistsNavKey =
      GlobalKey<NavigatorState>();

  List<Widget> get _screens => [
    const PearContentFrame(maxWidth: 1000, child: HomeScreen()),
    PearContentFrame(
      maxWidth: 1240,
      child: Navigator(
        key: _playlistsNavKey,
        onGenerateRoute: (settings) =>
            PearPageRoute(builder: (_) => const PlaylistsScreen()),
      ),
    ),
    PearContentFrame(
      maxWidth: 1000,
      child: ExploreScreen(isActive: _index == 2),
    ),
    const PearContentFrame(maxWidth: 1000, child: HistoryScreen()),
    const PearContentFrame(maxWidth: 860, child: SettingsScreen()),
  ];

  @override
  void initState() {
    super.initState();
    SessionDiagnostics.init();
    const MethodChannel('com.peerm.peerm_app/memory').setMethodCallHandler((
      call,
    ) async {
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
        } else if (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) {
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
    final isWide = MediaQuery.sizeOf(context).width >= 900;

    return PopScope(
      canPop:
          _index == 0 && !(_playlistsNavKey.currentState?.canPop() ?? false),
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
        body: isWide
            ? Row(
                children: [
                  SideRail(
                    selectedIndex: _index,
                    onDestinationSelected: _onDestinationSelected,
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: IndexedStack(
                            index: _index,
                            children: _screens,
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Center(
                            child: ConstrainedBox(
                              constraints:
                                  const BoxConstraints(maxWidth: 720),
                              child: const SafeArea(
                                top: false,
                                child: PlayerBar(),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : IndexedStack(index: _index, children: _screens),
        bottomNavigationBar: isWide
            ? null
            : SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const PlayerBar(),
                    _MinimalistNavBar(
                      selectedIndex: _index,
                      onDestinationSelected: _onDestinationSelected,
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  void _onDestinationSelected(int i) {
    if (i == 1 && _index == 1) {
      _playlistsNavKey.currentState?.popUntil((route) => route.isFirst);
    }
    setState(() => _index = i);
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
  /// has to hold them plus the bar's own border.
  static const double barHeight = 64;

  /// Corner rounding of the bar. Matches the mini player card above it (and the
  /// app's other cards) instead of using a full pill: two stacked shapes with
  /// radius 20 and "half the height" read as a mismatch, and the rounder ends
  /// also crowded the first and last labels.
  static const double barRadius = 20;

  /// Selected indicator: a capsule behind the icon alone. Sizing it from the
  /// icon instead of the label is what keeps the shape stable at any tab count,
  /// where a pill that had to wrap "Playlists" could only ever be as wide as a
  /// narrow item allows.
  static const double indicatorWidth = 48;
  static const double indicatorHeight = 30;

  /// Fixed row heights, so the indicator can be positioned exactly over the icon
  /// row without measuring text. Items apply no vertical margin of their own,
  /// so the content block is simply centred in the bar.
  static const double _iconRowHeight = indicatorHeight;
  static const double _labelRowHeight = 13;
  static const double _rowGap = 3;
  static const double _contentHeight =
      _iconRowHeight + _rowGap + _labelRowHeight;

  /// Outline width of the bar itself, which insets its content by this much.
  static const double _barBorder = 1;

  /// Top of the icon row inside the bar's inner box, derived from the very same
  /// numbers the item lays its content out with, so the two cannot drift apart.
  static double _indicatorTopFor(double barInnerHeight) =>
      (barInnerHeight - _contentHeight) / 2;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final hMargin = screenWidth < 380 ? 10.0 : 16.0;

    return Container(
      key: const ValueKey('nav_bar'),
      margin: EdgeInsets.fromLTRB(hMargin, 2, hMargin, 10),
      height: barHeight,
      decoration: BoxDecoration(
        // Same surface, border and shadow as the mini player card directly
        // above: the two are stacked, so a darker or duller bar reads as a
        // mismatch rather than as a deliberate hierarchy.
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(barRadius),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.14),
          width: _barBorder,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.60),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(barRadius),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = constraints.maxWidth / 5;
            final indicatorWidthForItem = indicatorWidth.clamp(
              0.0,
              itemWidth - 16,
            );
            return Stack(
              children: [
                // Gliding indicator, centred on the selected item's icon.
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  left:
                      selectedIndex * itemWidth +
                      (itemWidth - indicatorWidthForItem) / 2,
                  top: _indicatorTopFor(constraints.maxHeight),
                  height: indicatorHeight,
                  width: indicatorWidthForItem,
                  child: Container(
                    key: const ValueKey('nav_indicator'),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.24),
                      borderRadius: BorderRadius.circular(indicatorHeight / 2),
                    ),
                  ),
                ),
                // Navigation items. Filling the bar (rather than sitting at its
                // top with their intrinsic height) is what keeps each item's
                // icon row exactly where the indicator expects it.
                Positioned.fill(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
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
  void didUpdateWidget(covariant _NavBarItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != oldWidget.selectedIndex && _isHovered) {
      setState(() => _isHovered = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.index == widget.selectedIndex;
    final scheme = Theme.of(context).colorScheme;

    return Expanded(
      child: MouseRegion(
        onEnter: (event) {
          if (event.kind == PointerDeviceKind.mouse) {
            setState(() => _isHovered = true);
          }
        },
        onExit: (_) {
          if (_isHovered) {
            setState(() => _isHovered = false);
          }
        },
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapUp: (_) {
            setState(() {
              _isPressed = false;
              _isHovered = false;
            });
            TactileFeedback.click();
            widget.onTap();
          },
          onTapCancel: () => setState(() {
            _isPressed = false;
            _isHovered = false;
          }),
          behavior: HitTestBehavior.opaque,
          child: AnimatedScale(
            scale: _isPressed ? 0.90 : 1.0,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Fixed-height icon row that the selected indicator is
                // positioned over, so the two cannot drift apart. The hover
                // fill is the same capsule as the indicator: a rectangle
                // around the whole item competed with the selected shape and
                // read as a second, rougher pill.
                SizedBox(
                  height: _MinimalistNavBar.indicatorHeight,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOutCubic,
                      width: _MinimalistNavBar.indicatorWidth,
                      height: _MinimalistNavBar.indicatorHeight,
                      decoration: BoxDecoration(
                        color: (!isSelected && _isHovered)
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(
                          _MinimalistNavBar.indicatorHeight / 2,
                        ),
                      ),
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
                  ),
                ),
                const SizedBox(height: _MinimalistNavBar._rowGap),
                SizedBox(
                  height: _MinimalistNavBar._labelRowHeight,
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontSize: 10.5,
                          height: 1.0,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.w500,
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
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
