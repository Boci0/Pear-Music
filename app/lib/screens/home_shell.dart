import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/lyrics_service.dart';
import '../services/player_service.dart';
import '../services/player_theme.dart';
import '../services/session_diagnostics.dart';
import '../services/video_service.dart';
import '../theme/glass.dart';
import '../widgets/now_playing_panel.dart';
import '../widgets/pear_content_frame.dart';
import '../widgets/pear_menu_bar.dart';
import '../widgets/pear_page_route.dart';
import '../widgets/pear_status_bar.dart';
import '../widgets/player/theater_view.dart';
import '../widgets/player_bar.dart';
import '../widgets/system_bars.dart';
import '../widgets/tactile_button.dart';
import '../widgets/wide_rail.dart';
import 'explore_screen.dart';
import 'history_screen.dart';
import 'home_feed_screen.dart';
import 'home_screen.dart';
import 'playlist_detail_screen.dart';
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
  static bool usesWideShell(Size size) =>
      size.width >= 900 && (isDesktopOs || size.shortestSide >= 600);

  static bool get isDesktopOs =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Whether a window of [size] shows the permanent Now Playing pane, which
  /// doubles as the expanded player. A desktop has no mini player: the pane
  /// shows at every wide-shell width, always expanded.
  static bool usesNowPlayingPane(Size size) =>
      usesWideShell(size) && (isDesktopOs || size.width >= 1250);

  static final ValueNotifier<int> _expandPaneRequests = ValueNotifier<int>(0);

  /// Asks the shell to open the Now Playing pane in its expanded (player)
  /// state. The full-screen player calls this when the window grows wide
  /// enough for the pane, then closes itself, so a wide window always uses
  /// the pane instead of the separate phone-style player page.
  static void requestExpandedPane() => _expandPaneRequests.value++;

  static final ValueNotifier<int> _tabRequests = ValueNotifier<int>(0);
  static int _requestedTab = 0;

  /// Switches tab as a tap on the bar does. Called by the control port (a
  /// check driving a running build) and by History's empty state.
  static void requestTab(int index) {
    _requestedTab = index;
    _tabRequests.value++;
  }

  static final ValueNotifier<int> _panelRequests = ValueNotifier<int>(0);
  static bool? _requestedTheater;
  static bool? _requestedFold;

  /// Wide shell: opens or leaves Theater mode and folds or
  /// unfolds the player panel, as their buttons do. Only the control port
  /// calls this.
  static void requestPanel({bool? theater, bool? folded}) {
    _requestedTheater = theater;
    _requestedFold = folded;
    _panelRequests.value++;
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
  /// The screen shown. The app starts on Home, and back leads there.
  int _index = _homeTab;

  /// Screen index of the Home tab. It sits after the other five tabs so
  /// their indexes and the control port keep working unchanged.
  static const int _homeTab = 5;

  /// On a phone-shaped window the bar holds Home, Explore and Library;
  /// Playlists, History and Settings open from Home.
  static const List<int> _tabs = [_homeTab, 2, 0];

  /// The player panel folded to its slim strip.
  bool _paneFolded = false;

  /// Theater mode fills the centre with the player.
  bool _theater = false;

  /// The wide rail's search field, focused by Ctrl+K.
  final FocusNode _railSearchFocus = FocusNode();

  /// Whether Ctrl+K has a rail search field to focus (wide shell, no Theater).
  bool _railSearchKeyLive = false;
  AppLifecycleListener? _lifecycleListener;
  final GlobalKey<NavigatorState> _playlistsNavKey =
      GlobalKey<NavigatorState>();

  /// The playlist page on top of the Playlists tab, lit in the wide rail.
  late final _openPlaylist = _TopRouteName(
    (name) {
      if (mounted && name != _railPlaylist) {
        setState(() => _railPlaylist = name);
      }
    },
  );
  String? _railPlaylist;

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
  /// while the card shows a song's picture, which widens it.
  double _paneSlotWidthFor(
    Size window, {
    required bool video,
    bool folded = false,
  }) =>
      (folded
          ? NowPlayingPanel.stripWidth
          : video
          ? NowPlayingPanel.videoPaneWidthFor(window.width)
          : NowPlayingPanel.expandedPaneWidth) +
      _paneGutter;

  /// The least width the tabs keep beside the rail and the player panel. A
  /// narrower window folds the panel to its strip by itself.
  static const double _minCentre = 480;

  List<Widget> get _screens => [
    const PearContentFrame(maxWidth: _contentMaxWidth, child: HomeScreen()),
    PearContentFrame(
      maxWidth: _contentMaxWidth,
      child: Navigator(
        key: _playlistsNavKey,
        observers: [_openPlaylist],
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
    PearContentFrame(
      maxWidth: _contentMaxWidth,
      child: HomeFeedScreen(onOpenTab: _onDestinationSelected),
    ),
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
    HardwareKeyboard.instance.addHandler(_onRailSearchKey);
    HomeShell._expandPaneRequests.addListener(_onExpandPaneRequest);
    HomeShell._tabRequests.addListener(_onTabRequest);
    HomeShell._panelRequests.addListener(_onPanelRequest);
    HomeShell._popInnerPage = _popPlaylistsPage;
  }

  /// Ctrl+K focuses the rail search from anywhere in the window. A keyboard
  /// handler rather than Shortcuts: with nothing focused the key goes to the
  /// route's scope, above the shell, so a binding in here never saw it.
  bool _onRailSearchKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyK) {
      return false;
    }
    final keys = HardwareKeyboard.instance;
    if (!keys.isControlPressed ||
        keys.isAltPressed ||
        keys.isShiftPressed ||
        keys.isMetaPressed) {
      return false;
    }
    // A dialog or pushed page on top keeps the key.
    if (!mounted ||
        !_railSearchKeyLive ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }
    _railSearchFocus.requestFocus();
    return true;
  }

  void _onTabRequest() {
    if (!mounted) return;
    _onDestinationSelected(HomeShell._requestedTab.clamp(0, _homeTab));
  }

  void _onPanelRequest() {
    if (!mounted) return;
    setState(() {
      _theater = HomeShell._requestedTheater ?? _theater;
      _paneFolded = HomeShell._requestedFold ?? _paneFolded;
    });
  }

  bool _popPlaylistsPage() {
    final nav = _playlistsNavKey.currentState;
    if (nav == null || !nav.canPop()) return false;
    nav.pop();
    return true;
  }

  void _onExpandPaneRequest() {
    if (mounted && _paneFolded) setState(() => _paneFolded = false);
  }

  @override
  void dispose() {
    HomeShell._expandPaneRequests.removeListener(_onExpandPaneRequest);
    HomeShell._tabRequests.removeListener(_onTabRequest);
    HomeShell._panelRequests.removeListener(_onPanelRequest);
    HomeShell._popInnerPage = null;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    HardwareKeyboard.instance.removeHandler(_onRailSearchKey);
    _railSearchFocus.dispose();
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
    // A phone held sideways: the dock becomes a left rail.
    final landscapeRail = !isWide && size.height < 500;
    SystemBars.setSideways(landscapeRail);
    // At 1250+ (any width on a desktop) a permanent Now Playing pane sits on
    // the right and replaces the floating mini player.
    final useNowPlayingPane = HomeShell.usesNowPlayingPane(size);
    final currentSong = context.select<PlayerService, Song?>(
      (p) => p.currentSong,
    );
    final theater =
        _theater && useNowPlayingPane && currentSong != null;
    _railSearchKeyLive = isWide && !landscapeRail && !theater;
    // The pane sits inside a SafeArea, so a system inset at the side (a
    // display cutout, a side navigation bar) would shave its card narrower
    // than the width its content is laid out at and clip both edges. Give the
    // slot the inset back; with none, as on most tablets, nothing changes.
    final paneVideo =
        context.watch<VideoService?>()?.showingFor(currentSong) ?? false;
    // A window too narrow for the rail, the open panel and a usable centre
    // shows the panel folded; the user's own fold choice is left as it is.
    final autoFold =
        useNowPlayingPane &&
        size.width -
                WideRail.width -
                _paneSlotWidthFor(size, video: paneVideo) <
            _minCentre;
    final paneFolded = isWide && (_paneFolded || autoFold);
    final paneSlotWidth =
        _paneSlotWidthFor(size, video: paneVideo, folded: paneFolded) +
        MediaQuery.paddingOf(context).horizontal;

    return PopScope(
      canPop:
          _index == _homeTab &&
          !(_playlistsNavKey.currentState?.canPop() ?? false),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_index == 1 && (_playlistsNavKey.currentState?.canPop() ?? false)) {
          _playlistsNavKey.currentState!.pop();
        } else if (_index != _homeTab) {
          setState(() => _index = _homeTab);
        }
      },
      child: Scaffold(
        extendBody: true,
        body: landscapeRail
            ? Row(
                children: [
                  SafeArea(
                    right: false,
                    child: _LandscapeRail(
                      tabs: _tabs,
                      selectedIndex: _tabs.indexOf(
                        _index == 4 ? _homeTab : (_tabs.contains(_index) ? _index : 0),
                      ),
                      onDestinationSelected: (i) =>
                          _onDestinationSelected(_tabs[i]),
                    ),
                  ),
                  Expanded(
                    child: FadeTransition(
                      opacity: _tabFadeCurve,
                      child: SlideTransition(
                        position: _tabRise,
                        child: IndexedStack(index: _index, children: _screens),
                      ),
                    ),
                  ),
                ],
              )
            : isWide
            ? Column(
                  children: [
                    // Chrome strip: a graphite band + hairline so the top
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
                          WideRail(
                              selectedIndex: _index,
                              compact: theater,
                              searchFocus: _railSearchFocus,
                              onDestinationSelected: _onDestinationSelected,
                              openPlaylist: _railPlaylist,
                              onOpenLiked: () => _openInPlaylists(
                                const LikedPage(),
                                WideRail.liked,
                              ),
                              onOpenPlaylist: (p) => _openInPlaylists(
                                PlaylistDetailScreen(playlistId: p.id),
                                p.id,
                              ),
                              onSearch: (q) {
                                _onDestinationSelected(0);
                                HomeScreen.requestSearch(q);
                              },
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
                                  right: useNowPlayingPane && !theater
                                      ? paneSlotWidth
                                      : 0,
                                  // Theater covers the tabs; Offstage keeps
                                  // their state for when it closes.
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Offstage(
                                        offstage: theater,
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
                                      if (theater)
                                        TheaterView(
                                          onClose: () =>
                                              setState(() => _theater = false),
                                        ),
                                    ],
                                  ),
                                ),
                                if (useNowPlayingPane && !theater)
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
                                          child: paneFolded
                                              ? NowPlayingStrip(
                                                  // Too narrow to unfold: the
                                                  // full player is Theater.
                                                  onExpand: autoFold
                                                      ? _openTheater
                                                      : () => setState(
                                                          () => _paneFolded =
                                                              false,
                                                        ),
                                                )
                                              : NowPlayingPanel(
                                            onCollapse: () => setState(
                                              () => _paneFolded = true,
                                            ),
                                            onOpenTheater: _openTheater,
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
                )
            : FadeTransition(
                opacity: _tabFadeCurve,
                child: SlideTransition(
                  position: _tabRise,
                  child: IndexedStack(index: _index, children: _screens),
                ),
              ),
        bottomNavigationBar: isWide || landscapeRail
            ? null
            : SafeArea(top: false, child: _dock(context, currentSong)),
      ),
    );
  }

  /// The phone's floating navigation: the mini player as its own rounded
  /// card just above the tab capsule, both clear of the bottom edge. The
  /// Scaffold's extendBody lets the tabs scroll under it, and adds its height
  /// to their bottom padding so lists still end above it.
  Widget _dock(BuildContext context, Song? song) {
    final hMargin = MediaQuery.sizeOf(context).width < 380 ? 12.0 : 16.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(hMargin, 0, hMargin, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (song != null) ...[
            const _NavSurface(
              radius: _FloatingNavBar.miniRadius,
              child: PlayerBar(embedded: true),
            ),
            const SizedBox(height: 6),
          ],
          _navBar(),
        ],
      ),
    );
  }

  /// The phone nav bar for the tabs this layout shows. A screen without a
  /// tab of its own lights the tab it opens from: Settings lights Home, and
  /// Playlists and History light Library.
  Widget _navBar() {
    var slot = _tabs.indexOf(_index);
    if (slot < 0) slot = _tabs.indexOf(_index == 4 ? _homeTab : 0);
    return _FloatingNavBar(
      tabs: _tabs,
      selectedIndex: slot,
      onDestinationSelected: (i) => _onDestinationSelected(_tabs[i]),
    );
  }

  void _openTheater() => setState(() => _theater = true);

  /// Opens [page] inside the Playlists tab (a playlist or Liked songs from
  /// the wide rail), on top of the playlist list.
  void _openInPlaylists(Widget page, String name) {
    _onDestinationSelected(1);
    final nav = _playlistsNavKey.currentState;
    nav?.popUntil((route) => route.isFirst);
    nav?.push(
      PearPageRoute(builder: (_) => page, settings: RouteSettings(name: name)),
    );
  }

  void _onDestinationSelected(int i) {
    _theater = false;
    if (i == 1 && _index == 1) {
      _playlistsNavKey.currentState?.popUntil((route) => route.isFirst);
    }
    // Fade the body in on every destination tap: switching tabs (or re-tapping
    // the current one) reads as a deliberate transition instead of a hard cut.
    _tabFade.forward(from: 0);
    setState(() => _index = i);
  }
}

/// A rounded panel of the floating phone navigation: the Graphite panel
/// colour with a faint edge and no shadow.
class _NavSurface extends StatelessWidget {
  const _NavSurface({super.key, required this.radius, required this.child});

  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: PearGlassTokens.angularPanel,
        borderRadius: shape,
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: ClipRRect(borderRadius: shape, child: child),
    );
  }
}

/// The phone's floating tab capsule. The selected tab is an accent-tinted
/// pill with its icon and name; the others show only their icon.
class _FloatingNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  /// Screen indexes of the tabs on the bar, in order; [selectedIndex] and
  /// the index passed to [onDestinationSelected] are positions in this list.
  final List<int> tabs;

  const _FloatingNavBar({
    required this.tabs,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  static const List<({String label, IconData inactive, IconData active})>
      _all = [
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
    (
      label: 'Home',
      inactive: Icons.home_outlined,
      active: Icons.home_rounded,
    ),
  ];

  static const double height = 56;
  static const double pillHeight = 44;

  /// How long the selected pill takes to slide to a newly tapped tab.
  static const Duration slideDuration = Duration(milliseconds: 300);

  /// Corner radius of the mini player card floating above the capsule.
  static const double miniRadius = 20;

  @override
  Widget build(BuildContext context) {
    return _NavSurface(
      key: const ValueKey('nav_bar'),
      radius: height / 2,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final slot = constraints.maxWidth / tabs.length;
              return Stack(
                children: [
                  // Every slot is the same width, so the pill slides to the
                  // tapped tab at one fixed size: no stretch, no overshoot.
                  AnimatedPositioned(
                    duration: slideDuration,
                    curve: Curves.easeOutCubic,
                    left: slot * selectedIndex + 2,
                    width: slot - 4,
                    top: (height - pillHeight) / 2,
                    height: pillHeight,
                    child: DecoratedBox(
                      key: const ValueKey('nav_indicator'),
                      decoration: PearGlassTokens.navPill(
                        PearGlassTokens.navTint(Theme.of(context).colorScheme),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < tabs.length; i++)
                        Expanded(
                          child: _NavBarItem(
                            key: ValueKey('nav_tab_${_all[tabs[i]].label}'),
                            selected: i == selectedIndex,
                            label: _all[tabs[i]].label,
                            inactiveIcon: _all[tabs[i]].inactive,
                            activeIcon: _all[tabs[i]].active,
                            onTap: () => onDestinationSelected(i),
                          ),
                        ),
                    ],
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

/// A phone held sideways: a left rail with the tabs, and the
/// playing song's cover and play button at its foot, in place of the bottom
/// dock (which would take most of the height).
class _LandscapeRail extends StatelessWidget {
  final List<int> tabs;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  const _LandscapeRail({
    required this.tabs,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final player = context.watch<PlayerService>();
    final song = player.currentSong;
    return Container(
      key: const ValueKey('landscape_rail'),
      width: 72,
      decoration: BoxDecoration(
        color: PearGlassTokens.angularPanel,
        border: Border(
          right: BorderSide(
            color: Colors.white.withValues(alpha: PearGlassTokens.edge),
          ),
        ),
      ),
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                height: _itemHeight * tabs.length,
                child: Stack(
                  children: [
                    // The phone bar's pill, around the icon, sliding at one
                    // fixed size to the tapped tab.
                    AnimatedPositioned(
                      duration: _FloatingNavBar.slideDuration,
                      curve: Curves.easeOutCubic,
                      top: _itemHeight * selectedIndex + 5,
                      left: (72 - 52) / 2,
                      width: 52,
                      height: 30,
                      child: DecoratedBox(
                        key: const ValueKey('rail_indicator'),
                        decoration: PearGlassTokens.navPill(
                          PearGlassTokens.navTint(scheme),
                        ),
                      ),
                    ),
                    Column(
                      children: [
                        for (var i = 0; i < tabs.length; i++)
                          _railItem(
                            context,
                            scheme,
                            i,
                            _FloatingNavBar._all[tabs[i]],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (song != null) ...[
            GestureDetector(
              key: const ValueKey('landscape_rail_cover'),
              onTap: () => PlayerBar.openPlayer(context),
              child: SizedBox(
                width: 40,
                height: 40,
                child: PlayerBarThumb(song: song, radius: 6),
              ),
            ),
            const SizedBox(height: 2),
            TactileBounce(
              onTap: () => context.read<AppController>().togglePlayback(),
              scaleDown: 0.88,
              tooltip: player.playing ? 'Pause' : 'Play',
              child: SizedBox(
                width: 40,
                height: 40,
                child: Icon(
                  player.playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  size: 32,
                  color: scheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  /// Height of one tab on the rail, so the pill knows where each one sits.
  static const double _itemHeight = 56;

  Widget _railItem(
    BuildContext context,
    ColorScheme scheme,
    int i,
    ({String label, IconData inactive, IconData active}) tab,
  ) {
    final selected = i == selectedIndex;
    final color = selected ? scheme.primary : Colors.white.withValues(alpha: 0.55);
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          TactileFeedback.click();
          onDestinationSelected(i);
        },
        child: Container(
          width: 72,
          height: _itemHeight,
          padding: const EdgeInsets.only(top: 5),
          child: Column(
            children: [
              SizedBox(
                width: 52,
                height: 30,
                child: Icon(
                  selected ? tab.active : tab.inactive,
                  size: 20,
                  color: color,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                tab.label,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavBarItem extends StatefulWidget {
  final bool selected;
  final String label;
  final IconData inactiveIcon;
  final IconData activeIcon;
  final VoidCallback onTap;

  const _NavBarItem({
    super.key,
    required this.selected,
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

  @override
  void didUpdateWidget(covariant _NavBarItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected && _isHovered) {
      setState(() => _isHovered = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final scheme = Theme.of(context).colorScheme;
    final idle = Colors.white.withValues(alpha: _isHovered ? 0.85 : 0.55);
    // The selected pill itself is drawn by the bar and slides under the
    // items. Here, in step with it, the icon glides from the centre to the
    // left and the name comes in beside it; leaving a tab plays it backwards.
    final item = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      height: _FloatingNavBar.pillHeight,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: PearGlassTokens.navPill(
        !selected && _isHovered
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.transparent,
      ),
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: selected ? 1 : 0),
        duration: _FloatingNavBar.slideDuration,
        curve: Curves.easeOutCubic,
        builder: (context, t, _) => LayoutBuilder(
          builder: (context, box) {
            const iconSize = 21.0;
            const gap = 6.0;
            final style = TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color.lerp(idle, scheme.primary, t),
            );
            final name = TextPainter(
              text: TextSpan(text: widget.label, style: style),
              textDirection: TextDirection.ltr,
              textScaler: MediaQuery.textScalerOf(context),
              maxLines: 1,
            )..layout();
            // A slot too narrow for the whole name shrinks it to fit.
            final nameWidth = math.min(
              name.width,
              box.maxWidth - 20 - iconSize - gap,
            );
            final centred = (box.maxWidth - iconSize) / 2;
            final besideName =
                (box.maxWidth - iconSize - gap - nameWidth) / 2;
            final iconLeft = lerpDouble(centred, besideName, t)!;
            final top = (box.maxHeight - iconSize) / 2;
            final color = Color.lerp(idle, scheme.primary, t);
            return Stack(
              children: [
                // Outline and filled icon in one spot, cross-fading.
                Positioned(
                  left: iconLeft,
                  top: top,
                  child: Stack(
                    children: [
                      Opacity(
                        opacity: 1 - t,
                        child: Icon(
                          widget.inactiveIcon,
                          size: iconSize,
                          color: color,
                        ),
                      ),
                      Opacity(
                        opacity: t,
                        child: Icon(
                          widget.activeIcon,
                          size: iconSize,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
                if (t > 0)
                  Positioned(
                    left: iconLeft + iconSize + gap,
                    top: 0,
                    bottom: 0,
                    width: nameWidth,
                    // The leaving name clears at once; the arriving one waits
                    // until the pill is most of the way there, so no name
                    // shows outside the pill.
                    child: Opacity(
                      opacity: Interval(selected ? 0.6 : 0.85, 1)
                          .transform(t),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(widget.label, maxLines: 1, style: style),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (event) {
          if (event.kind == PointerDeviceKind.mouse) {
            setState(() => _isHovered = true);
          }
        },
        onExit: (_) {
          if (_isHovered) setState(() => _isHovered = false);
        },
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _isHovered = false);
            TactileFeedback.click();
            widget.onTap();
          },
          child: Center(
            child: Tooltip(message: widget.label, child: item),
          ),
        ),
      ),
    );
  }
}

/// Reports the name of the route on top of a navigator whenever it changes.
class _TopRouteName extends NavigatorObserver {
  _TopRouteName(this.onChanged);

  final ValueChanged<String?> onChanged;

  void _top(Route<dynamic>? route) =>
      // Observers fire during the navigator's own build or pop.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => onChanged(route?.settings.name),
      );

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _top(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _top(previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _top(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _top(newRoute);
}
