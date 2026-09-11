import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../widgets/player_bar.dart';
import 'playlist_detail_screen.dart';

/// Lists the user's playlists with create / play / rename / delete.
class PlaylistsScreen extends StatelessWidget {
  final bool showPlayerBar;
  const PlaylistsScreen({super.key, this.showPlayerBar = false});

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
      // If pushed as a separate route, show the mini player bar. When embedded
      // inside HomeShell, HomeShell's own PlayerBar handles playback controls.
      bottomNavigationBar: showPlayerBar ? const PlayerBar() : null,
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
    final controller = context.read<AppController>();

    // Find up to 4 preview songs for artwork mosaic preview
    final previewSongs = <Song>[];
    for (final id in playlist.songIds) {
      final s = controller.findSongById(id);
      if (s != null) {
        previewSongs.add(s);
        if (previewSongs.length == 4) break;
      }
    }

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2.5),
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PlaylistDetailScreen(playlistId: playlist.id),
              ),
            ),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: isActive
                    ? LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          theme.colorScheme.primary.withValues(alpha: 0.16),
                          theme.colorScheme.primary.withValues(alpha: 0.02),
                        ],
                      )
                    : null,
                color: isActive
                    ? null
                    : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                border: Border.all(
                  color: isActive
                      ? theme.colorScheme.primary.withValues(alpha: 0.30)
                      : Colors.white.withValues(alpha: 0.06),
                  width: 1,
                ),
              ),
              child: SizedBox(
                height: 64,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    if (isActive)
                      Positioned(
                        left: 4,
                        child: Container(
                          width: 3.5,
                          height: 24,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(left: 14, right: 8),
                      child: Row(
                        children: [
                          _PlaylistArtwork(
                            songs: previewSongs,
                            isActive: isActive,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  playlist.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontSize: 15,
                                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                                    color: isActive ? theme.colorScheme.primary : null,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${playlist.songIds.length} track${playlist.songIds.length == 1 ? '' : 's'}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: isActive ? 'Playing' : 'Play all',
                            icon: Icon(
                              isActive
                                  ? Icons.pause_circle_filled_rounded
                                  : Icons.play_circle_fill_rounded,
                              color: theme.colorScheme.primary,
                              size: 28,
                            ),
                            onPressed: onPlay,
                          ),
                          PopupMenuButton<String>(
                            icon: Icon(
                              Icons.more_vert_rounded,
                              size: 20,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            onSelected: (v) {
                              if (v == 'delete') onDelete();
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.delete_outline_rounded,
                                      size: 18,
                                      color: theme.colorScheme.error,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Delete playlist',
                                      style: TextStyle(color: theme.colorScheme.error),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
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

class _PlaylistArtwork extends StatelessWidget {
  final List<Song> songs;
  final bool isActive;

  const _PlaylistArtwork({
    required this.songs,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget content;
    if (songs.isEmpty) {
      content = Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        ),
        child: Icon(
          Icons.queue_music_rounded,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          size: 22,
        ),
      );
    } else {
      final first = songs.first;
      final bytes = ArtworkPalette.cachedBytes(first);
      final isNetwork = first.artwork != null && first.artwork!.startsWith('http');
      if (isNetwork) {
        content = ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(
            first.artwork!,
            width: 46,
            height: 46,
            cacheWidth: 96,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _fallback(scheme),
          ),
        );
      } else if (bytes != null && bytes.isNotEmpty) {
        content = ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            bytes,
            width: 46,
            height: 46,
            cacheWidth: 96,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _fallback(scheme),
          ),
        );
      } else {
        content = FutureBuilder<Uint8List?>(
          future: ArtworkPalette.bytesAsync(first),
          builder: (context, snap) {
            final b = snap.data;
            if (b != null && b.isNotEmpty) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  b,
                  width: 46,
                  height: 46,
                  cacheWidth: 96,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _fallback(scheme),
                ),
              );
            }
            return _fallback(scheme);
          },
        );
      }
    }

    if (!isActive) return content;
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.65),
          width: 1.5,
        ),
      ),
      child: content,
    );
  }

  Widget _fallback(ColorScheme scheme) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primaryContainer,
            scheme.primary.withValues(alpha: 0.5),
          ],
        ),
      ),
      child: Icon(
        Icons.queue_music_rounded,
        color: scheme.onPrimaryContainer,
        size: 22,
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
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.queue_music_rounded,
                size: 38,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'No playlists yet',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Group your favorite songs together into custom collections.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text(
                'New playlist',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
