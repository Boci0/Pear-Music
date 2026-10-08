import 'dart:math' as math;
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

  /// Whether a window of [size] gets the wide shell (menu bar, side rail).
  /// Desktop operating systems always do at 900+ px. Other platforms (phones
  /// in landscape, tablets) only switch once the short side is at least
  /// 600 logical px, so a rotated phone never turns into a desktop window
  /// with a menu bar and side rail.
  static bool usesWideShell(Size size) {
    final isDesktopOs =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    return size.width >= 900 && (isDesktopOs || size.shortestSide >= 600);
  }

  /// Whether a window of [size] shows the permanent Now Playing pane, which
  /// doubles as the expanded player.
  static bool usesNowPlayingPane(Size size) =>
      usesWideShell(size) && size.width >= 1250;

  static final ValueNotifier<int> _expandPaneRequests = ValueNotifier<int>(0);

  /// Asks the shell to open the Now Playing pane in its expanded (player)
  /// state. The full-screen player calls this when the window grows wide
  /// enough for the pane, then closes itself, so a wide window always uses
  /// the pane instead of the separate phone-style player page.
  static void requestExpandedPane() => _expandPaneRequests.value++;

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
    duration: const Duration(milliseconds: 260),
    value: 1,
  );
  late final Animation<double> _tabFadeCurve = CurvedAnimation(
    parent: _tabFade,
    curve: Curves.easeOutCubic,
  );

  /// The new tab rises a few pixels as it fades in, so switching tabs has a
  /// little motion rather than only a cross-fade.
  late final Animation<Offset> _tabRise = Tween<Offset>(
    begin: const Offset(0, 0.012),
    end: Offset.zero,
  ).animate(_tabFadeCurve);

  /// One shared content width for every tab. Same cap means every tab's
  /// header and content dock to the same edges and end at the same x, so no
  /// tab shows a dead strip beside the Now Playing pane on wide windows.
  static const double _contentMaxWidth = 1460;

  /// Gutter between the pane card and the window edge. Lives next to the pane
  /// width constants so the animated width and the padding cannot drift.
  static const double _paneGutter = 12;

  /// Width the Now Playing pane settles at, gutter included.
  double get _paneSlotWidth =>
      (_playerExpanded
          ? NowPlayingPanel.expandedPaneWidth
          : NowPlayingPanel.compactPaneWidth) +
      _paneGutter;

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
    HomeShell._expandPaneRequests.addListener(_onExpandPaneRequest);
  }

  void _onExpandPaneRequest() {
    if (mounted && !_playerExpanded) {
      setState(() => _playerExpanded = true);
    }
  }

  @override
  void dispose() {
    HomeShell._expandPaneRequests.removeListener(_onExpandPaneRequest);
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
    final isWide = HomeShell.usesWideShell(size);
    // Old-school desktop layout: at 1250+ a permanent Now Playing pane sits
    // on the right and replaces the floating mini player.
    final useNowPlayingPane = HomeShell.usesNowPlayingPane(size);

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
                            // The tabs take the pane's final width once, when
                            // the toggle starts, and only the pane animates on
                            // top. Animating a Row sibling instead re-laid out
                            // every tab (IndexedStack lays out all five) on
                            // each frame, which made expand/collapse stutter.
                            child: Stack(
                              children: [
                                Positioned(
                                  left: 0,
                                  top: 0,
                                  bottom: 0,
                                  right: useNowPlayingPane
                                      ? _paneSlotWidth
                                      : 0,
                                  child: RepaintBoundary(
                                    child: Stack(
                                      children: [
                                        Positioned.fill(
                                          child: FadeTransition(
                                            opacity: _tabFadeCurve,
                                            child: SlideTransition(
                                              position: _tabRise,
                                              child: IndexedStack(
                                                index: _index,
                                                children: _screens,
                                              ),
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
                                                constraints:
                                                    const BoxConstraints(
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
                                ),
                                if (useNowPlayingPane)
                                  Positioned(
                                    top: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: AnimatedContainer(
                                      duration: NowPlayingPanel
                                          .expandTransitionDuration,
                                      curve: Curves.easeOutCubic,
                                      width: _paneSlotWidth,
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
                                            onToggleExpanded: () =>
                                                setState(() {
                                                  _playerExpanded =
                                                      !_playerExpanded;
                                                }),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
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
                child: SlideTransition(
                  position: _tabRise,
                  child: IndexedStack(index: _index, children: _screens),
                ),
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

  static const List<({String label, IconData inactive, IconData active})>
      _destinations = [
    (
      label: 'Library',
      inactive: Icons.library_music_outlined,
      active: Icons.library_music_rounded,
    ),
    (
      label: 'Playlists',
      inactive: Icons.queue_music_outlined,
      active: Icons.queue_music_rounded,
    ),
    (
      label: 'Explore',
      inactive: Icons.explore_outlined,
      active: Icons.explore_rounded,
    ),
    (
      label: 'History',
      inactive: Icons.history_outlined,
      active: Icons.history_rounded,
    ),
    (
      label: 'Settings',
      inactive: Icons.settings_outlined,
      active: Icons.settings_rounded,
    ),
  ];

  /// Bar height. It holds the pill plus [pillInsetY] above and below it.
  static const double barHeight = 54;

  /// Corner rounding of the bar: the same radius as the mini player card
  /// directly above it, so the two read as panels of one family.
  static const double barRadius = PearGlassTokens.floatingRadius;

  /// Gap between the pill and the top and bottom of the bar.
  static const double pillInsetY = 5;
  static const double pillHeight = barHeight - pillInsetY * 2;

  /// Corner radius of the pill: the bar's radius minus the gap around the pill,
  /// so its corners run concentric with the bar's own (the same relationship
  /// the side rail's logo tile has with its panel). Below half the height, so
  /// the ends read as softly rounded rather than a full capsule.
  static const double pillRadius = PearGlassTokens.selectionPillRadius;

  /// Fixed row heights of an item's icon and label, so the pill can be centred
  /// on them without measuring. With the gap they make a 35px block inside a
  /// 44px pill: a small icon and a label tucked close under it.
  static const double iconSize = 20;
  static const double iconRowHeight = 20;
  static const double labelRowHeight = 12;
  static const double rowGap = 3;

  /// Empty space the pill leaves either side of its label, and the smallest
  /// pill (an icon and a little air).
  static const double labelPadX = 15;
  static const double minPillWidth = 52;

  /// Room kept between the bar's ends and the items, and between the pill and
  /// the bar's edge. The inner padding is what lets the first and last tabs
  /// grow a full-size pill instead of being cut short by the bar's end.
  static const double edgePad = 6;
  static const double edgeInset = 4;

  /// Width of the pill for tab [index]: its label plus [labelPadX] each side,
  /// kept symmetric and inside the bar. Sized from the label rather than from
  /// the slot, so every tab gets the same breathing room however narrow the
  /// slots are; it may be wider than its slot, because only one pill shows.
  @visibleForTesting
  static double pillWidthFor(
    BuildContext context,
    int index,
    double barWidth,
  ) {
    final slot = (barWidth - edgePad * 2) / _destinations.length;
    final center = edgePad + slot * (index + 0.5);
    final painter = TextPainter(
      text: TextSpan(
        text: _destinations[index].label,
        style: navLabelStyle(context, selected: true, color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final natural = painter.width / 2 + labelPadX;
    final room = math.min(center, barWidth - center) - edgeInset;
    final half = math.min(math.max(natural, minPillWidth / 2), room);
    return half * 2;
  }

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
        blur: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(barRadius),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final barWidth = constraints.maxWidth;
              final slot = (barWidth - edgePad * 2) / _destinations.length;
              final widths = [
                for (var i = 0; i < _destinations.length; i++)
                  pillWidthFor(context, i, barWidth),
              ];
              final selectedWidth = widths[selectedIndex];
              final selectedCenter = edgePad + slot * (selectedIndex + 0.5);
              return Stack(
                children: [
                  // Gliding pill behind the selected icon and label. It resizes
                  // as it moves, because each label has its own width. Same
                  // timing as the side rail's selection, and no overshoot: it
                  // would run past the bar's ends and be clipped there.
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                    left: selectedCenter - selectedWidth / 2,
                    top: (constraints.maxHeight - pillHeight) / 2,
                    height: pillHeight,
                    width: selectedWidth,
                    child: Container(
                      key: const ValueKey('nav_indicator'),
                      // The glass family's selection pill, shared with the
                      // side rail.
                      decoration: PearGlassTokens.selectionPill(
                        scheme,
                        radius: pillRadius,
                      ),
                    ),
                  ),
                  // Navigation items. Filling the bar keeps each item's content
                  // centred where the pill expects it.
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: edgePad),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < _destinations.length; i++)
                            _NavBarItem(
                              index: i,
                              selectedIndex: selectedIndex,
                              label: _destinations[i].label,
                              inactiveIcon: _destinations[i].inactive,
                              activeIcon: _destinations[i].active,
                              pillWidth: widths[i],
                              onTap: () => onDestinationSelected(i),
                            ),
                        ],
                      ),
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

/// Text style of a tab label. Shared by the item and by the pill's width
/// measurement, so the pill is sized from exactly what is drawn.
@visibleForTesting
TextStyle navLabelStyle(
  BuildContext context, {
  required bool selected,
  required Color color,
}) =>
    (Theme.of(context).textTheme.labelSmall ?? const TextStyle()).copyWith(
      fontSize: 10.5,
      height: 1.0,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      color: color,
      letterSpacing: -0.2,
    );

class _NavBarItem extends StatefulWidget {
  final int index;
  final int selectedIndex;
  final String label;
  final IconData inactiveIcon;
  final IconData activeIcon;

  /// Width of this tab's pill, used for its hover fill so a hovered tab shows
  /// the same shape the selected one does.
  final double pillWidth;
  final VoidCallback onTap;

  const _NavBarItem({
    required this.index,
    required this.selectedIndex,
    required this.label,
    required this.inactiveIcon,
    required this.activeIcon,
    required this.pillWidth,
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
    final color = isSelected
        ? scheme.primary
        : _isHovered
            ? Colors.white.withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: 0.45);

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
            // The hover fill is the pill itself, so a hovered tab previews the
            // shape it would get when selected. It may be wider than the tab's
            // slot, hence the overflow box.
            child: Center(
              child: OverflowBox(
                minWidth: 0,
                maxWidth: widget.pillWidth,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutCubic,
                  width: widget.pillWidth,
                  height: _MinimalistNavBar.pillHeight,
                  decoration: BoxDecoration(
                    color: (!isSelected && _isHovered)
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(
                      _MinimalistNavBar.pillRadius,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        height: _MinimalistNavBar.iconRowHeight,
                        child: Center(
                          child: Icon(
                            isSelected
                                ? widget.activeIcon
                                : widget.inactiveIcon,
                            size: _MinimalistNavBar.iconSize,
                            color: color,
                          ),
                        ),
                      ),
                      const SizedBox(height: _MinimalistNavBar.rowGap),
                      SizedBox(
                        height: _MinimalistNavBar.labelRowHeight,
                        child: Center(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              style: navLabelStyle(
                                context,
                                selected: isSelected,
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
        ),
      ),
    );
  }
}
