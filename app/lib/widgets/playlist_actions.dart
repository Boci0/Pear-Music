import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';

/// Shows a bottom sheet letting the user add [song] to an existing playlist
/// or create a new one. Shows a confirmation SnackBar afterwards.
Future<void> showAddToPlaylistSheet(
  BuildContext context,
  AppController controller,
  Song song,
) async {
  final result = await showModalBottomSheet<String>(
    context: context,
    builder: (_) => _PlaylistPickerSheet(controller: controller, song: song),
  );
  if (result == null || !context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(result)));
}

class _PlaylistPickerSheet extends StatefulWidget {
  final AppController controller;
  final Song song;

  const _PlaylistPickerSheet({
    required this.controller,
    required this.song,
  });

  @override
  State<_PlaylistPickerSheet> createState() => _PlaylistPickerSheetState();
}

class _PlaylistPickerSheetState extends State<_PlaylistPickerSheet> {
  Future<void> _promptNewPlaylistName() async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, nameController.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;

    final playlist = await widget.controller.createPlaylist(name);
    if (!mounted) return;
    final added = await widget.controller
        .addSongToPlaylist(playlist.id, widget.song.id);
    if (!mounted) return;
    Navigator.pop(
      context,
      added ? 'Added "${widget.song.title}" to "${playlist.name}"' : 'Already in "${playlist.name}"',
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlists = widget.controller.playlists;
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              'Add "${widget.song.title}" to…',
              style: theme.textTheme.titleMedium,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final pl in playlists)
                  ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: Text(pl.name),
                    subtitle: Text(
                      '${pl.songIds.length} song${pl.songIds.length == 1 ? '' : 's'}',
                    ),
                    onTap: () async {
                      final added = await widget.controller
                          .addSongToPlaylist(pl.id, widget.song.id);
                      if (!context.mounted) return;
                      Navigator.pop(
                        context,
                        added
                            ? 'Added "${widget.song.title}" to "${pl.name}"'
                            : 'Already in "${pl.name}"',
                      );
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('New playlist'),
                  onTap: _promptNewPlaylistName,
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
