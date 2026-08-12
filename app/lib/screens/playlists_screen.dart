import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/playlist.dart';
import '../widgets/player_bar.dart';
import 'playlist_detail_screen.dart';

/// Lists the user's playlists with create / play / rename / delete.
class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final playlists = controller.playlists;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlists'),
        actions: [
          IconButton(
            tooltip: 'New playlist',
            icon: const Icon(Icons.add),
            onPressed: () => _createPlaylist(context, controller),
          ),
        ],
      ),
      // The mini player is hidden behind this pushed screen, so surface it
      // here too — otherwise playing from a playlist gives no feedback.
      bottomNavigationBar: const PlayerBar(),
      body: playlists.isEmpty
          ? _EmptyPlaylists(onCreate: () => _createPlaylist(context, controller))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: playlists.length,
              itemBuilder: (context, i) => _PlaylistTile(
                playlist: playlists[i],
                isActive: controller.player.currentSong != null &&
                    playlists[i].songIds
                        .contains(controller.player.currentSong!.id),
                onPlay: () => controller.playPlaylist(playlists[i]),
                onDelete: () => _confirmDelete(context, controller, playlists[i]),
              ),
            ),
    );
  }

  Future<void> _createPlaylist(
    BuildContext context,
    AppController controller,
  ) async {
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
    if (name == null || name.trim().isEmpty) return;
    await controller.createPlaylist(name);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AppController controller,
    Playlist playlist,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${playlist.name}"?'),
        content: const Text('The songs stay in your library; only the playlist '
            'is removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await controller.deletePlaylist(playlist.id);
    }
  }
}

class _PlaylistTile extends StatelessWidget {
  final Playlist playlist;
  final bool isActive;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  const _PlaylistTile({
    required this.playlist,
    required this.isActive,
    required this.onPlay,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.queue_music,
              color: theme.colorScheme.onPrimaryContainer),
        ),
        title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${playlist.songIds.length} song${playlist.songIds.length == 1 ? '' : 's'}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: isActive ? 'Playing from this playlist' : 'Play all',
              icon: Icon(
                isActive ? Icons.play_circle : Icons.play_arrow,
                color: isActive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              onPressed: onPlay,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                if (v == 'delete') onDelete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
              ],
            ),
          ],
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlaylistDetailScreen(playlistId: playlist.id),
          ),
        ),
      ),
    );
  }
}

class _EmptyPlaylists extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptyPlaylists({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.queue_music,
                size: 64, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('No playlists yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Create a playlist to group your songs.\nLong-press any song to add it.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('New playlist'),
            ),
          ],
        ),
      ),
    );
  }
}
