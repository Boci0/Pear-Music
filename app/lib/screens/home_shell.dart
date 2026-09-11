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
import 'explore_screen.dart';
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

  late final List<Widget> _screens = [
    const HomeScreen(),
    Navigator(
      key: _playlistsNavKey,
      onGenerateRoute: (settings) => PearPageRoute(
        builder: (_) => const PlaylistsScreen(),
      ),
    ),
    const ExploreScreen(),
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      height: 58,
      decoration: BoxDecoration(
        color: const Color(0xFF14141A),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 1,
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
        borderRadius: BorderRadius.circular(28),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = constraints.maxWidth / 4;
            return Stack(
              children: [
                // Gliding solid pill indicator across tabs
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  left: selectedIndex * itemWidth + 5,
                  top: 5,
                  bottom: 5,
                  width: itemWidth - 10,
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(22),
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
                      label: 'Settings',
                      inactiveIcon: Icons.settings_outlined,
                      activeIcon: Icons.settings_rounded,
                      onTap: () => onDestinationSelected(3),
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
            widget.onTap();
          },
          onTapCancel: () => setState(() => _isPressed = false),
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: AnimatedScale(
              scale: _isPressed ? 0.90 : (_isHovered ? 1.05 : 1.0),
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: (!isSelected && _isHovered)
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isSelected ? widget.activeIcon : widget.inactiveIcon,
                      size: 20,
                      color: isSelected
                          ? scheme.primary
                          : _isHovered
                              ? Colors.white.withValues(alpha: 0.75)
                              : Colors.white.withValues(alpha: 0.45),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                        color: isSelected
                            ? scheme.primary
                            : _isHovered
                                ? Colors.white.withValues(alpha: 0.75)
                                : Colors.white.withValues(alpha: 0.45),
                        letterSpacing: -0.1,
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
