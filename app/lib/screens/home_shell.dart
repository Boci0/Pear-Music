import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../services/artwork_palette.dart';
import '../services/lyrics_service.dart';
import '../services/player_theme.dart';
import '../services/session_diagnostics.dart';
import '../theme/glass.dart';
import '../widgets/now_playing_panel.dart';
import '../widgets/pear_content_frame.dart';
import '../widgets/pear_menu_bar.dart';
import '../widgets/pear_page_route.dart';
import '../widgets/pear_status_bar.dart';
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

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  // At 1250+ the Now Playing pane doubles as the expanded player: tapping the
  // compact pane grows it in place instead of pushing the full-screen route.
  bool _playerExpanded = false;
  AppLifecycleListener? _lifecycleListener;
  final GlobalKey<NavigatorState> _playlistsNavKey =
      GlobalKey<NavigatorState>();

  /// Quick fade-in when the selected tab changes. The IndexedStack itself is
  /// untouched (state is preserved); this only softens the hard cut between
  /// tabs on every platform.
  late final AnimationController _tabFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );
  late final Animation<double> _tabFadeCurve = CurvedAnimation(
    parent: _tabFade,
    curve: Curves.easeOutQuad,
  );

  /// One shared content width for every tab. Same cap means every tab's
  /// header and content dock to the same edges and end at the same x, so no
  /// tab shows a dead strip beside the Now Playing pane on wide windows.
  static const double _contentMaxWidth = 1460;

  /// Gutter between the pane card and the window edge. Lives next to the pane
  /// width constants so the animated width and the padding cannot drift.
  static const double _paneGutter = 12;

  List<Widget> get _screens => [
    const PearContentFrame(maxWidth: _contentMaxWidth, child: HomeScreen()),
    PearContentFrame(
      maxWidth: _contentMaxWidth,
      child: Navigator(
        key: _playlistsNavKey,
        onGenerateRoute: (settings) =>
            PearPageRoute(builder: (_) => const PlaylistsScreen()),
      ),
    ),
    PearContentFrame(
      maxWidth: _contentMaxWidth,
      child: ExploreScreen(isActive: _index == 2),
    ),
    const PearContentFrame(maxWidth: _contentMaxWidth, child: HistoryScreen()),
    const PearContentFrame(maxWidth: _contentMaxWidth, child: SettingsScreen()),
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
    _tabFade.dispose();
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
    final size = MediaQuery.sizeOf(context);
    final windowWidth = size.width;
    // Desktop operating systems always get the wide shell. Other platforms
    // (phones in landscape, tablets) only switch once the short side is at
    // least 600 logical px, so a rotated phone never turns into a desktop
    // window with a menu bar and side rail.
    final isDesktopOs =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    final isWide =
        windowWidth >= 900 && (isDesktopOs || size.shortestSide >= 600);
    // Old-school desktop layout: at 1250+ a permanent Now Playing pane sits
    // on the right and replaces the floating mini player.
    final useNowPlayingPane = isWide && windowWidth >= 1250;

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
            ? CallbackShortcuts(
                bindings: {
                  // Escape collapses the expanded pane back to its compact
                  // dock, like closing the old full-screen player.
                  const SingleActivator(LogicalKeyboardKey.escape): () {
                    if (_playerExpanded) {
                      setState(() => _playerExpanded = false);
                    }
                  },
                },
                child: Column(
                  children: [
                    // Chrome strip: a frosted glass band + hairline so the top
                    // bar reads as chrome from a distance instead of dead
                    // space (mirror of the status bar at the bottom).
                    const PearGlass(
                      shadow: false,
                      edge: PearGlassEdge.bottom,
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: PearMenuBar(),
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          SideRail(
                            selectedIndex: _index,
                            onDestinationSelected: _onDestinationSelected,
                          ),
                          Expanded(
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: FadeTransition(
                                    opacity: _tabFadeCurve,
                                    child: IndexedStack(
                                      index: _index,
                                      children: _screens,
                                    ),
                                  ),
                                ),
                                if (!useNowPlayingPane)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 720,
                                        ),
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
                          if (useNowPlayingPane)
                            AnimatedContainer(
                              duration:
                                  NowPlayingPanel.expandTransitionDuration,
                              curve: Curves.easeOutCubic,
                              width:
                                  (_playerExpanded
                                      ? NowPlayingPanel.expandedPaneWidth
                                      : NowPlayingPanel.compactPaneWidth) +
                                  _paneGutter,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  0,
                                  8,
                                  _paneGutter,
                                  8,
                                ),
                                child: SafeArea(
                                  top: false,
                                  child: NowPlayingPanel(
                                    expanded: _playerExpanded,
                                    onToggleExpanded: () => setState(() {
                                      _playerExpanded = !_playerExpanded;
                                    }),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const PearStatusBar(),
                  ],
                ),
              )
            : FadeTransition(
                opacity: _tabFadeCurve,
                child: IndexedStack(index: _index, children: _screens),
              ),
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
    // Fade the body in on every destination tap: switching tabs (or re-tapping
    // the current one) reads as a deliberate transition instead of a hard cut.
    _tabFade.forward(from: 0);
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

  /// Corner rounding of the bar: the same radius as the mini player card
  /// directly above it, so the two read as panels of one family.
  static const double barRadius = PearGlassTokens.floatingRadius;

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
      child: PearGlass(
        borderRadius: BorderRadius.circular(barRadius),
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
