import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../screens/player_screen.dart';
import '../services/player_service.dart';
import 'pear_page_route.dart';
import 'player/playback_speed_dialog.dart';

/// Classic desktop menu bar (File / Playback / View / Help) for wide windows,
/// the way Windows apps have always been laid out.
class PearMenuBar extends StatelessWidget {
  final int selectedTab;
  final void Function(int index) onSelectTab;

  const PearMenuBar({
    super.key,
    required this.selectedTab,
    required this.onSelectTab,
  });

  static const ButtonStyle _itemStyle = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(0, 32)),
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  static const ButtonStyle _topStyle = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(0, 30)),
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  @override
  Widget build(BuildContext context) {
    final controller = context.read<AppController>();
    final player = context.watch<PlayerService>();
    final theme = Theme.of(context);

    Widget check() =>
        Icon(Icons.check_rounded, size: 16, color: theme.colorScheme.primary);

    final loopLabel = switch (player.loopMode) {
      LoopSetting.off => 'Repeat: Off',
      LoopSetting.all => 'Repeat: All',
      LoopSetting.one => 'Repeat: One',
    };

    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: MenuBar(
        key: const ValueKey('pear_menu_bar'),
        style: const MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Colors.transparent),
          elevation: WidgetStatePropertyAll(0),
          padding: WidgetStatePropertyAll(EdgeInsets.only(left: 8, right: 8)),
        ),
        children: [
          SubmenuButton(
            style: _topStyle,
            menuChildren: [
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.audio_file_outlined, size: 16),
                onPressed: () => controller.addFilesFromPicker(),
                child: const Text('Add audio files...'),
              ),
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.ios_share_rounded, size: 16),
                onPressed: () => controller.exportLibraryProfile(),
                child: const Text('Export library profile...'),
              ),
              const Divider(height: 1),
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.restart_alt_rounded, size: 16),
                onPressed: () => controller.restartApp(),
                child: const Text('Restart'),
              ),
            ],
            child: const Text('File'),
          ),
          SubmenuButton(
            style: _topStyle,
            menuChildren: [
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: Icon(
                  player.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: 16,
                ),
                onPressed: () => controller.togglePlayback(),
                child: Text(player.playing ? 'Pause' : 'Play'),
              ),
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.skip_previous_rounded, size: 16),
                onPressed: () => controller.previousTrack(),
                child: const Text('Previous'),
              ),
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.skip_next_rounded, size: 16),
                onPressed: () => controller.nextTrack(),
                child: const Text('Next'),
              ),
              const Divider(height: 1),
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.shuffle_rounded, size: 16),
                trailingIcon: player.shuffle ? check() : null,
                onPressed: () => player.toggleShuffle(),
                child: const Text('Shuffle'),
              ),
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.repeat_rounded, size: 16),
                trailingIcon: player.loopMode != LoopSetting.off
                    ? check()
                    : null,
                onPressed: () => player.toggleLoop(),
                child: Text(loopLabel),
              ),
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.auto_awesome_rounded, size: 16),
                trailingIcon: player.autoplay ? check() : null,
                onPressed: () => player.setAutoplay(!player.autoplay),
                child: const Text('Endless Play'),
              ),
              const Divider(height: 1),
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.speed_rounded, size: 16),
                onPressed: () => showPlaybackSpeedDialog(context, player),
                child: const Text('Playback speed...'),
              ),
            ],
            child: const Text('Playback'),
          ),
          SubmenuButton(
            style: _topStyle,
            menuChildren: [
              for (final (i, label) in const [
                (0, 'Library'),
                (1, 'Playlists'),
                (2, 'Explore'),
                (3, 'History'),
                (4, 'Settings'),
              ])
                MenuItemButton(
                  style: _itemStyle,
                  leadingIcon: Icon(switch (i) {
                    0 => Icons.library_music_outlined,
                    1 => Icons.queue_music_rounded,
                    2 => Icons.explore_outlined,
                    3 => Icons.history_rounded,
                    _ => Icons.settings_outlined,
                  }, size: 16),
                  trailingIcon: selectedTab == i ? check() : null,
                  onPressed: () => onSelectTab(i),
                  child: Text(label),
                ),
              const Divider(height: 1),
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(
                  Icons.play_circle_outline_rounded,
                  size: 16,
                ),
                onPressed: () => Navigator.of(
                  context,
                ).push(PearPageRoute(builder: (_) => const PlayerScreen())),
                child: const Text('Player'),
              ),
            ],
            child: const Text('View'),
          ),
          SubmenuButton(
            style: _topStyle,
            menuChildren: [
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.info_outline_rounded, size: 16),
                onPressed: () => showAboutDialog(
                  context: context,
                  applicationName: 'Pear Music',
                  applicationIcon: Icon(
                    Icons.music_note_rounded,
                    size: 32,
                    color: theme.colorScheme.primary,
                  ),
                  children: const [
                    Text(
                      'A local first music player with YouTube streaming support.',
                    ),
                  ],
                ),
                child: const Text('About Pear Music'),
              ),
            ],
            child: const Text('Help'),
          ),
        ],
      ),
    );
  }
}
