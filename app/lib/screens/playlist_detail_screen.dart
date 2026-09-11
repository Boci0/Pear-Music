import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../widgets/player_bar.dart';

/// Shows the songs in one playlist: play all, play a specific song in the
/// playlist order, remove a song from the playlist, rename or delete it.
class PlaylistDetailScreen extends StatefulWidget {
  final String playlistId;

  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  List<String>? _optimisticIds;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final theme = Theme.of(context);
    final player = controller.player;
    final playlist = controller.playlists
        .where((p) => p.id == widget.playlistId)
        .firstOrNull;

    // The playlist was deleted (e.g. from another flow) — leave.
    if (playlist == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Playlist')),
        body: const Center(child: Text('This playlist no longer exists')),
      );
    }

    if (_optimisticIds != null) {
      final currentSet = playlist.songIds.toSet();
      final optSet = _optimisticIds!.toSet();
      if (currentSet.length != optSet.length || !currentSet.containsAll(optSet)) {
        _optimisticIds = null;
      } else if (listEquals(_optimisticIds, playlist.songIds)) {
        _optimisticIds = null;
      }
    }

    final effectiveIds = _optimisticIds ?? playlist.songIds;

    final songs = [
      for (final id in effectiveIds)
        if (controller.findSongById(id) != null)
          controller.findSongById(id)!,
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.queue_music_rounded,
                            size: 15,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${songs.length} song${songs.length == 1 ? '' : 's'}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: songs.isEmpty
                            ? null
                            : () => controller.playPlaylist(playlist),
                        icon: const Icon(Icons.play_arrow_rounded, size: 22),
                        label: const Text(
                          'Play all',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton.filledTonal(
                      tooltip: 'Shuffle playlist',
                      style: IconButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        minimumSize: const Size(44, 44),
                      ),
                      onPressed: songs.isEmpty
                          ? null
                          : () {
                              if (!controller.player.shuffle) {
                                controller.player.toggleShuffle();
                              }
                              controller.playPlaylist(playlist);
                            },
                      icon: const Icon(Icons.shuffle_rounded, size: 20),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: songs.isEmpty
                ? const _EmptyPlaylist()
                : ReorderableListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemExtent: 61.0,
                    buildDefaultDragHandles: false,
                    itemCount: songs.length,
                    onReorderItem: (oldIndex, newIndex) =>
                        _reorder(controller, playlist, oldIndex, newIndex),
                    proxyDecorator: (child, index, animation) {
                      return AnimatedBuilder(
                        animation: animation,
                        builder: (context, child) {
                          final t = Curves.easeInOut.transform(animation.value);
                          return Material(
                            color: const Color(0xFF1B1B20),
                            elevation: 8 * t,
                            shadowColor: Colors.black.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(12),
                            child: child,
                          );
                        },
                        child: child,
                      );
                    },
                    itemBuilder: (context, i) {
                      final song = songs[i];
                      final isCurrent = song.id == player.currentSong?.id;
                      final isPlaying = isCurrent && player.playing;
                      return _SongRow(
                        key: ValueKey(song.id),
                        song: song,
                        isCurrent: isCurrent,
                        isPlaying: isPlaying,
                        index: i,
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
    AppController controller,
    Playlist playlist,
    int oldIndex,
    int newIndex,
  ) {
    // onReorderItem already adjusts newIndex for the removed item, so a
    // direct removeAt + insert gives the correct order.
    final ids = List<String>.from(_optimisticIds ?? playlist.songIds);
    if (oldIndex < 0 || oldIndex >= ids.length || newIndex < 0 || newIndex >= ids.length) {
      return;
    }
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex, moved);
    setState(() {
      _optimisticIds = ids;
    });
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
  final int index;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  const _SongRow({
    super.key,
    required this.song,
    required this.isCurrent,
    required this.isPlaying,
    required this.index,
    required this.onPlay,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initialBytes = ArtworkPalette.cachedBytes(song);
    final isNetwork = song.artwork != null && song.artwork!.startsWith('http');

    Widget artworkWidget;
    if (isNetwork) {
      artworkWidget = RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(
            song.artwork!,
            key: ValueKey('pl_net_${song.id}'),
            width: 44,
            height: 44,
            cacheWidth: 96,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _placeholder(theme.colorScheme),
          ),
        ),
      );
    } else if (initialBytes != null && initialBytes.isNotEmpty) {
      artworkWidget = RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            initialBytes,
            key: ValueKey('pl_mem_${song.id}'),
            width: 44,
            height: 44,
            cacheWidth: 96,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _placeholder(theme.colorScheme),
          ),
        ),
      );
    } else {
      artworkWidget = RepaintBoundary(
        child: FutureBuilder<Uint8List?>(
          key: ValueKey('pl_async_${song.id}'),
          initialData: initialBytes,
          future: ArtworkPalette.bytesAsync(song),
          builder: (context, snapshot) {
            final bytes = snapshot.data ?? initialBytes;
            if (bytes == null || bytes.isEmpty) return _placeholder(theme.colorScheme);
            return ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                bytes,
                key: ValueKey('pl_mem_${song.id}'),
                width: 44,
                height: 44,
                cacheWidth: 96,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _placeholder(theme.colorScheme),
              ),
            );
          },
        ),
      );
    }

    if (isCurrent) {
      artworkWidget = Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.65),
            width: 1.5,
          ),
        ),
        child: artworkWidget,
      );
    }

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1.5),
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPlay,
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: isCurrent
                    ? LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          theme.colorScheme.primary.withValues(alpha: 0.16),
                          theme.colorScheme.primary.withValues(alpha: 0.02),
                        ],
                      )
                    : null,
                border: isCurrent
                    ? Border.all(
                        color: theme.colorScheme.primary.withValues(alpha: 0.20),
                        width: 1,
                      )
                    : null,
              ),
              child: SizedBox(
                height: 58,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    if (isCurrent)
                      Positioned(
                        left: 4,
                        child: Container(
                          width: 3.5,
                          height: 22,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(left: 14, right: 6),
                      child: Row(
                        children: [
                          artworkWidget,
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontSize: 14.5,
                                    fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
                                    color: isCurrent ? theme.colorScheme.primary : null,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  song.sizeLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isCurrent)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Icon(
                                Icons.graphic_eq_rounded,
                                size: 18,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          IconButton(
                            tooltip: 'Remove from playlist',
                            icon: Icon(
                              Icons.remove_circle_outline_rounded,
                              size: 19,
                              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                            ),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            onPressed: onRemove,
                          ),
                          ReorderableDragStartListener(
                            index: index,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                              child: Icon(
                                Icons.drag_handle_rounded,
                                size: 20,
                                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                              ),
                            ),
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

  Widget _placeholder(ColorScheme scheme) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primaryContainer,
            scheme.primary.withValues(alpha: 0.55),
          ],
        ),
      ),
      child: Icon(
        isCurrent ? Icons.music_note_rounded : Icons.audiotrack_rounded,
        color: scheme.onPrimaryContainer,
        size: 22,
      ),
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
