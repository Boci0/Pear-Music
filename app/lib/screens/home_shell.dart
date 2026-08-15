import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../widgets/desktop_player_bar.dart';
import '../widgets/player_bar.dart';
import 'devices_screen.dart';
import 'home_screen.dart';
import 'playlist_detail_screen.dart';
import 'settings_screen.dart';

/// Root shell with responsive switching between mobile touch layout and
/// desktop sidebar + full-width media bar layout.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _screens = [
    HomeScreen(),
    DevicesScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isDesktopLayout = width >= 850;

    if (isDesktopLayout) {
      return Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  _DesktopSidebar(
                    selectedIndex: _index,
                    onDestinationSelected: (i) => setState(() => _index = i),
                  ),
                  const VerticalDivider(width: 1, thickness: 1),
                  Expanded(
                    child: IndexedStack(
                      index: _index,
                      children: _screens,
                    ),
                  ),
                ],
              ),
            ),
            const DesktopPlayerBar(),
          ],
        ),
      );
    }

    // Mobile layout
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: _screens,
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const PlayerBar(),
          NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music),
                label: 'Library',
              ),
              NavigationDestination(
                icon: Icon(Icons.devices_other_outlined),
                selectedIcon: Icon(Icons.devices_other),
                label: 'Devices',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DesktopSidebar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  const _DesktopSidebar({
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final controller = context.watch<AppController>();
    final playlists = controller.playlists;
    final pairedCount = controller.pairedDevices.length;

    return Container(
      width: 230,
      color: scheme.surfaceContainerLow,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // App Header / Branding
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
              child: Row(
                children: [
                  Image.asset(
                    'assets/pear_logo.png',
                    width: 30,
                    height: 30,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.music_note,
                      color: scheme.primary,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Pear Music',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // Main Nav Items
            _SidebarNavTile(
              icon: Icons.library_music_outlined,
              selectedIcon: Icons.library_music,
              label: 'Library',
              count: controller.songs.length,
              isSelected: selectedIndex == 0,
              onTap: () => onDestinationSelected(0),
            ),
            _SidebarNavTile(
              icon: Icons.devices_other_outlined,
              selectedIcon: Icons.devices_other,
              label: 'Devices',
              count: pairedCount > 0 ? pairedCount : null,
              isSelected: selectedIndex == 1,
              onTap: () => onDestinationSelected(1),
            ),
            _SidebarNavTile(
              icon: Icons.settings_outlined,
              selectedIcon: Icons.settings,
              label: 'Settings',
              isSelected: selectedIndex == 2,
              onTap: () => onDestinationSelected(2),
            ),

            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Divider(height: 1),
            ),

            // Playlists Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
              child: Row(
                children: [
                  Text(
                    'PLAYLISTS',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'New playlist',
                    icon: const Icon(Icons.add, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _createPlaylistDialog(context, controller),
                  ),
                ],
              ),
            ),

            // Playlists List
            Expanded(
              child: playlists.isEmpty
                  ? Center(
                      child: Text(
                        'No playlists yet',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: playlists.length,
                      itemBuilder: (context, i) {
                        final pl = playlists[i];
                        return ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          leading: Icon(
                            Icons.playlist_play,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                          title: Text(
                            pl.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 13,
                            ),
                          ),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    PlaylistDetailScreen(playlistId: pl.id),
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createPlaylistDialog(
    BuildContext context,
    AppController controller,
  ) async {
    final textController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Playlist'),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, textController.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await controller.library.createPlaylist(name);
    }
  }
}

class _SidebarNavTile extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final int? count;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarNavTile({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.count,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: isSelected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(
                  isSelected ? selectedIcon : icon,
                  size: 20,
                  color: isSelected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                      color: isSelected
                          ? scheme.onPrimaryContainer
                          : scheme.onSurface,
                    ),
                  ),
                ),
                if (count != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? scheme.onPrimaryContainer.withValues(alpha: 0.12)
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$count',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 11,
                        color: isSelected
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant,
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
