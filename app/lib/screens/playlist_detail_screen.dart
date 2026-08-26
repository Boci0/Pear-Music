import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../widgets/player_bar.dart';

/// Shows the songs in one playlist: play all, play a specific song in the
/// playlist order, remove a song from the playlist, rename or delete it.
class PlaylistDetailScreen extends StatelessWidget {
  final String playlistId;

  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final theme = Theme.of(context);
    final player = controller.player;
    final playlist = controller.playlists
        .where((p) => p.id == playlistId)
        .firstOrNull;

    // The playlist was deleted (e.g. from another flow) — leave.
    if (playlist == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Playlist')),
        body: const Center(child: Text('This playlist no longer exists')),
      );
    }

    final songs = [
      for (final id in playlist.songIds)
        if (controller.library.findById(id) != null)
          controller.library.findById(id)!,
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(playlist.name),
        actions: [
          IconButton(
            tooltip: 'Rename',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _rename(context, controller, playlist),
          ),
          IconButton(
            tooltip: 'Delete playlist',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context, controller, playlist),
          ),
        ],
      ),
      // Surface the mini player here too (it's hidden behind this pushed
      // screen) so playing from a playlist gives visible feedback.
      bottomNavigationBar: const PlayerBar(),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.queue_music,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      '${songs.length} song${songs.length == 1 ? '' : 's'}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: songs.isEmpty
                        ? null
                        : () => controller.playPlaylist(playlist),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play all'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: songs.isEmpty
                ? const _EmptyPlaylist()
                : ReorderableListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: songs.length,
                    onReorderItem: (oldIndex, newIndex) =>
                        _reorder(context, controller, playlist, songs, oldIndex, newIndex),
                    itemBuilder: (context, i) {
                      final song = songs[i];
                      final isCurrent = song.id == player.currentSong?.id;
                      final isPlaying = isCurrent && player.playing;
                      return _SongRow(
                        key: ValueKey(song.id),
                        song: song,
                        isCurrent: isCurrent,
                        isPlaying: isPlaying,
                        onPlay: isPlaying
                            ? () => controller.togglePlayback()
                            : () => controller.player.playSong(
                                  song,
                                  queue: songs,
                                  sourceId: 'playlist:${playlist.id}',
                                  sourceTitle: playlist.name,
                                ),
                        onRemove: () => controller
                            .removeSongFromPlaylist(playlist.id, song.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _reorder(
    BuildContext context,
    AppController controller,
    Playlist playlist,
    List<Song> songs,
    int oldIndex,
    int newIndex,
  ) {
    // onReorderItem already adjusts newIndex for the removed item, so a
    // direct removeAt + insert gives the correct order.
    final ids = [...playlist.songIds];
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex, moved);
    controller.reorderPlaylist(playlist.id, ids);
  }

  Future<void> _rename(
    BuildContext context,
    AppController controller,
    Playlist playlist,
  ) async {
    final controller_ = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename playlist'),
        content: TextField(
          controller: controller_,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller_.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await controller.renamePlaylist(playlist.id, name);
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
        content: const Text(
            'The songs stay in your library; only the playlist is removed.'),
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
      if (context.mounted) Navigator.of(context).pop();
    }
  }
}

class _SongRow extends StatelessWidget {
  final Song song;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  const _SongRow({
    super.key,
    required this.song,
    required this.isCurrent,
    required this.isPlaying,
    required this.onPlay,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      tileColor: isCurrent
          ? (theme.brightness == Brightness.dark
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.28)
              : theme.colorScheme.primaryContainer.withValues(alpha: 0.40))
          : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Icon(
        isCurrent ? Icons.graphic_eq : Icons.audiotrack,
        color: isCurrent
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isCurrent
            ? TextStyle(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              )
            : null,
      ),
      subtitle: Text(song.sizeLabel, style: theme.textTheme.bodySmall),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: isPlaying ? 'Pause' : 'Play',
            icon: Icon(
              isPlaying ? Icons.pause_circle : Icons.play_circle,
              color: theme.colorScheme.primary,
            ),
            onPressed: onPlay,
          ),
          IconButton(
            tooltip: 'Remove from playlist',
            icon: Icon(Icons.remove_circle_outline,
                color: theme.colorScheme.error),
            onPressed: onRemove,
          ),
        ],
      ),
      onTap: onPlay,
    );
  }
}

class _EmptyPlaylist extends StatelessWidget {
  const _EmptyPlaylist();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.music_off,
                size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('This playlist is empty', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Long-press a song in your library to add it here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
