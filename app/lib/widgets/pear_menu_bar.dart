import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/player_service.dart';
import 'about_dialog.dart';
import 'import_export_sheet.dart';
import 'player/playback_speed_dialog.dart';

/// Classic desktop menu bar for wide windows. Deliberately app-level only:
/// navigation lives in the side rail and transport lives on the Now Playing
/// pane, so the menus never repeat either.
class PearMenuBar extends StatelessWidget {
  const PearMenuBar({super.key});

  static const ButtonStyle _itemStyle = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(0, 34)),
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
    ),
  );

  static const ButtonStyle _topStyle = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(0, 32)),
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
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
                child: const Text('Export library backup...'),
              ),
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.playlist_add_rounded, size: 16),
                onPressed: () => showPlaylistImportDialog(context, controller),
                child: const Text('Import playlists...'),
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
              // Transport first, with the keys the app actually listens to
              // shown right in the menu, so the shortcuts are discoverable
              // without reading the README.
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: Icon(
                  player.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: 16,
                ),
                onPressed: player.currentSong == null
                    ? null
                    : () => controller.togglePlayback(),
                shortcut: const SingleActivator(LogicalKeyboardKey.space),
                child: Text(player.playing ? 'Pause' : 'Play'),
              ),
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.skip_previous_rounded, size: 16),
                onPressed: player.currentSong == null
                    ? null
                    : () => controller.previousTrack(),
                shortcut: const SingleActivator(LogicalKeyboardKey.comma),
                child: const Text('Previous Track'),
              ),
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.skip_next_rounded, size: 16),
                onPressed: player.currentSong == null
                    ? null
                    : () => controller.nextTrack(),
                shortcut: const SingleActivator(LogicalKeyboardKey.period),
                child: const Text('Next Track'),
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
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: const Icon(Icons.info_outline_rounded, size: 16),
                onPressed: () => showPearMusicAboutDialog(context),
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
