import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/artwork_service.dart';
import '../widgets/pear_page_route.dart';
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
    final currentSongId = controller.player.currentSong?.id;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 14,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/pear_logo.png',
              width: 28,
              height: 28,
              filterQuality: FilterQuality.medium,
            ),
            const SizedBox(width: 8),
            const Text(
              'Playlists',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
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
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              itemExtent: 72.0,
              itemCount: playlists.length,
              itemBuilder: (context, i) => _PlaylistTile(
                key: ValueKey(playlists[i].id),
                playlist: playlists[i],
                isActive: currentSongId != null &&
                    playlists[i].songIds.contains(currentSongId),
                onPlay: () => controller.playPlaylist(playlists[i]),
                onRename: () => _renamePlaylist(context, controller, playlists[i]),
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
      useRootNavigator: true,
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
      useRootNavigator: true,
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

  Future<void> _renamePlaylist(
    BuildContext context,
    AppController controller,
    Playlist playlist,
  ) async {
    final nameController = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename playlist'),
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
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await controller.renamePlaylist(playlist.id, name.trim());
  }
}

class _PlaylistTile extends StatelessWidget {
  final Playlist playlist;
  final bool isActive;
  final VoidCallback onPlay;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _PlaylistTile({
    super.key,
    required this.playlist,
    required this.isActive,
    required this.onPlay,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = context.read<AppController>();

    // Find the first valid song for playlist artwork preview
    Song? firstSong;
    for (final id in playlist.songIds) {
      final s = controller.findSongById(id);
      if (s != null) {
        firstSong = s;
        break;
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
              PearPageRoute(
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
                            firstSong: firstSong,
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
                                    letterSpacing: -0.1,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isActive
                                        ? theme.colorScheme.primary.withValues(alpha: 0.15)
                                        : Colors.white.withValues(alpha: 0.05),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '${playlist.songIds.length} track${playlist.songIds.length == 1 ? '' : 's'}',
                                    style: TextStyle(
                                      color: isActive
                                          ? theme.colorScheme.primary
                                          : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                    ),
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
                          IconButton(
                            icon: Icon(
                              Icons.more_vert_rounded,
                              size: 20,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            tooltip: 'Playlist options',
                            onPressed: () => _showMenu(context),
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

  Future<void> _showMenu(BuildContext context) async {
    final controller = context.read<AppController>();
    final theme = Theme.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              subtitle: Text(
                '${playlist.songIds.length} track${playlist.songIds.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              dense: true,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('Play all'),
              onTap: () => Navigator.pop(ctx, 'play'),
            ),
            ListTile(
              leading: const Icon(Icons.shuffle_rounded),
              title: const Text('Shuffle'),
              onTap: () => Navigator.pop(ctx, 'shuffle'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename playlist'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline_rounded,
                color: theme.colorScheme.error,
              ),
              title: Text(
                'Delete playlist',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'play') {
      onPlay();
    } else if (action == 'shuffle') {
      if (!controller.player.shuffle) {
        controller.player.toggleShuffle();
      }
      controller.playPlaylist(playlist);
    } else if (action == 'rename') {
      onRename();
    } else if (action == 'delete') {
      onDelete();
    }
  }
}

class _PlaylistArtwork extends StatelessWidget {
  final Song? firstSong;
  final bool isActive;

  const _PlaylistArtwork({
    required this.firstSong,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget content;
    if (firstSong == null) {
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
      final song = firstSong!;
      final bytes = ArtworkPalette.cachedBytes(song) ??
          (song.artwork != null &&
                  song.artwork!.isNotEmpty &&
                  !song.artwork!.startsWith('http') &&
                  song.artwork!.length < 65536
              ? ArtworkPalette.bytes(song)
              : null);
      final isNetwork = song.artwork != null && song.artwork!.startsWith('http');
      if (isNetwork) {
        content = ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(
            ArtworkService.optimizeArtworkUrl(song.artwork!),
            key: ValueKey('pl_net_${song.id}'),
            width: 46,
            height: 46,
            cacheWidth: 96,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _fallback(scheme),
          ),
        );
      } else if (bytes != null && bytes.isNotEmpty) {
        content = ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            bytes,
            key: ValueKey('pl_mem_${song.id}'),
            width: 46,
            height: 46,
            cacheWidth: 96,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _fallback(scheme),
          ),
        );
      } else {
        content = FutureBuilder<Uint8List?>(
          key: ValueKey('pl_async_${song.id}'),
          initialData: bytes,
          future: ArtworkPalette.bytesAsync(song),
          builder: (context, snap) {
            final b = snap.data ?? bytes;
            if (b != null && b.isNotEmpty) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  b,
                  key: ValueKey('pl_mem_${song.id}'),
                  width: 46,
                  height: 46,
                  cacheWidth: 96,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
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
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.25),
                  width: 1,
                ),
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
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Group your favorite songs together into custom collections.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
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
