import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/lyrics_service.dart';
import '../services/player_service.dart';
import '../services/player_theme.dart';
import '../services/session_diagnostics.dart';
import '../services/video_service.dart';
import '../theme/glass.dart';
import '../theme/pear_style.dart';
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
  const HomeShell({super.key, this.singleDock = true});

  /// Phone layout: the mini player and the nav bar share one glass panel.
  /// False brings back the two floating pills (kept for the design gallery).
  final bool singleDock;

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

  static final ValueNotifier<int> _tabRequests = ValueNotifier<int>(0);
  static int _requestedTab = 0;

  /// Switches tab as a tap on the bar does. Only the control port (a check
  /// driving a running build) calls this.
  static void requestTab(int index) {
    _requestedTab = index;
    _tabRequests.value++;
  }

  static bool Function()? _popInnerPage;

  /// Closes the page open inside the Playlists tab, if one is; false when
  /// there was none. Only the control port calls this.
  static bool popInnerPage() => _popInnerPage?.call() ?? false;

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

  /// Width the Now Playing pane settles at, gutter included. [video] is true
  /// while the expanded card shows a song's picture, which widens it.
  double _paneSlotWidthFor(Size window, {required bool video}) =>
      (_playerExpanded
          ? (video
                ? NowPlayingPanel.videoPaneWidthFor(window.width)
                : NowPlayingPanel.expandedPaneWidth)
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
    HomeShell._tabRequests.addListener(_onTabRequest);
    HomeShell._popInnerPage = _popPlaylistsPage;
  }

  void _onTabRequest() {
    if (!mounted) return;
    _onDestinationSelected(
      HomeShell._requestedTab.clamp(0, _screens.length - 1),
    );
  }

  bool _popPlaylistsPage() {
    final nav = _playlistsNavKey.currentState;
    if (nav == null || !nav.canPop()) return false;
    nav.pop();
    return true;
  }

  void _onExpandPaneRequest() {
    if (mounted && !_playerExpanded) {
      setState(() => _playerExpanded = true);
    }
  }

  @override
  void dispose() {
    HomeShell._expandPaneRequests.removeListener(_onExpandPaneRequest);
    HomeShell._tabRequests.removeListener(_onTabRequest);
    HomeShell._popInnerPage = null;
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
    final currentSong = context.select<PlayerService, Song?>(
      (p) => p.currentSong,
    );
    // The pane sits inside a SafeArea, so a system inset at the side (a
    // display cutout, a side navigation bar) would shave its card narrower
    // than the width its content is laid out at and clip both edges. Give the
    // slot the inset back; with none, as on most tablets, nothing changes.
    final paneSlotWidth =
        _paneSlotWidthFor(
          size,
          video:
              _playerExpanded &&
              (context.watch<VideoService?>()?.showingFor(currentSong) ??
                  false),
        ) +
        MediaQuery.paddingOf(context).horizontal;

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
                                      ? paneSlotWidth
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
                                      width: paneSlotWidth,
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
                child: size.height < 500 &&
                        currentSong != null &&
                        widget.singleDock
                    // Sideways: the dock lays the mini player and the nav bar
                    // side by side in one panel, so nothing shows between them.
                    ? _dock(context, currentSong, sideways: true)
                    : size.height < 500 && currentSong != null
                    // A phone held sideways has no height for the mini player
                    // stacked on the nav bar, so they share one row and the
                    // list keeps the room.
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          // The nav bar keeps 10 below it and the player bar 6,
                          // so lift the player by the difference to share a
                          // baseline.
                          const Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(bottom: 4),
                              child: PlayerBar(),
                            ),
                          ),
                          SizedBox(
                            width: math.min(380, size.width * 0.5),
                            child: _MinimalistNavBar(
                              selectedIndex: _index,
                              onDestinationSelected: _onDestinationSelected,
                            ),
                          ),
                        ],
                      )
                    : widget.singleDock
                    ? _dock(context, currentSong)
                    : Column(
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

  /// One glass panel holding the mini player over the nav bar, tinted like
  /// the mini player, with a hairline between them: no gap for the list to
  /// show through and no second surface tone.
  Widget _dock(BuildContext context, Song? song, {bool sideways = false}) {
    final theme = Theme.of(context);
    final hMargin = MediaQuery.sizeOf(context).width < 380 ? 10.0 : 16.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(hMargin, 2, hMargin, 10),
      child: PearGlass(
        borderRadius: BorderRadius.circular(PearGlassTokens.floatingRadius),
        tint: song == null ? null : PlayerBar.tintFor(theme, song),
        blur: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            PearGlassTokens.r(PearGlassTokens.floatingRadius),
          ),
          child: sideways
              ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Expanded(child: PlayerBar(embedded: true)),
                      Container(
                        width: 1,
                        height: 36,
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                      SizedBox(
                        width: math.min(380, MediaQuery.sizeOf(context).width * 0.5),
                        child: _MinimalistNavBar(
                          embedded: true,
                          selectedIndex: _index,
                          onDestinationSelected: _onDestinationSelected,
                        ),
                      ),
                    ],
                  )
              : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (song != null) ...[
                const PlayerBar(embedded: true),
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: PearGlassTokens.dockInset,
                  endIndent: PearGlassTokens.dockInset,
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ],
              _MinimalistNavBar(
                embedded: true,
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

  /// Drawn inside the phone dock: no margins and no glass of its own.
  final bool embedded;

  const _MinimalistNavBar({
    this.embedded = false,
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

  /// The least room a pill keeps either side of its label.
  static const double minLabelPadX = 9;

  /// The narrowest a pill may get, as width over height.
  static const double minPillAspect = 1.35;
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
    double barWidth, {
    bool embedded = false,
  }) {
    final pad = embedded ? PearGlassTokens.dockInset : edgePad;
    final slot = (barWidth - pad * 2) / _destinations.length;
    final center = pad + slot * (index + 0.5);
    final painter = TextPainter(
      text: TextSpan(
        text: navLabelText(_destinations[index].label),
        style: navLabelStyle(context, selected: true, color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    // Angular styles draw square highlights that would touch or cover the
    // next tab, so each one keeps to its own slot with a small gap.
    if (PearStyles.spec.angular) {
      return math.min(painter.width + 2 * minLabelPadX, slot - 4);
    }
    final natural = painter.width / 2 + labelPadX;
    final toEdge = math.min(center, barWidth - center);
    final room = toEdge - edgeInset;
    if (!embedded) {
      return math.min(math.max(natural, minPillWidth / 2), room) * 2;
    }
    // In the dock an edge pill lines up with the dock's margin while its label
    // keeps [minLabelPadX] either side; on a narrow phone it gives up the
    // alignment before the label gets cramped.
    final aligned = toEdge - PearGlassTokens.dockInset;
    final least = math.max(
      painter.width / 2 + minLabelPadX,
      pillHeight * minPillAspect / 2,
    );
    final wanted = math.max(natural, minPillWidth / 2);
    var half = math.min(wanted, aligned);
    if (half < least) half = math.min(wanted, room);
    // An end pill a few pixels short of the margin stretches onto it, so its
    // edge lines up with the cover and the hairline above it.
    final atEnd = index == 0 || index == _destinations.length - 1;
    if (atEnd && aligned > half && aligned - half <= 6) half = aligned;
    return half * 2;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final hMargin = screenWidth < 380 ? 10.0 : 16.0;

    return Container(
      key: const ValueKey('nav_bar'),
      // In the dock the pill keeps the dock's margin below it too.
      margin: embedded
          ? const EdgeInsets.only(
              bottom: PearGlassTokens.dockInset - pillInsetY,
            )
          : EdgeInsets.fromLTRB(hMargin, 2, hMargin, 10),
      height: barHeight,
      child: PearGlass(
        borderRadius: BorderRadius.circular(barRadius),
        blur: true,
        surface: !embedded,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(PearGlassTokens.r(barRadius)),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final barWidth = constraints.maxWidth;
              final pad = embedded ? PearGlassTokens.dockInset : edgePad;
              final slot = (barWidth - pad * 2) / _destinations.length;
              final widths = [
                for (var i = 0; i < _destinations.length; i++)
                  pillWidthFor(context, i, barWidth, embedded: embedded),
              ];
              final selectedWidth = widths[selectedIndex];
              final selectedCenter = pad + slot * (selectedIndex + 0.5);
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
                        radius: embedded
                            ? PearGlassTokens.dockInnerRadius
                            : pillRadius,
                      ),
                    ),
                  ),
                  // Navigation items. Filling the bar keeps each item's content
                  // centred where the pill expects it.
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: pad),
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

/// A tab label as drawn: spaced capitals in angular styles.
String navLabelText(String label) =>
    PearStyles.spec.angular ? label.toUpperCase() : label;

/// Text style of a tab label. Shared by the item and by the pill's width
/// measurement, so the pill is sized from exactly what is drawn.
@visibleForTesting
TextStyle navLabelStyle(
  BuildContext context, {
  required bool selected,
  required Color color,
}) =>
    (Theme.of(context).textTheme.labelSmall ?? const TextStyle()).copyWith(
      fontSize: PearStyles.spec.angular ? 9 : 10.5,
      height: 1.0,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      color: color,
      letterSpacing: PearStyles.spec.angular ? 0.9 : -0.2,
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
                      PearGlassTokens.r(_MinimalistNavBar.pillRadius),
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
                              navLabelText(widget.label),
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
