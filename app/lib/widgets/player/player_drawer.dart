import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/player_service.dart';
import '../../services/stream_cache_manager.dart';

/// Mobile drawer: view Playing Queue or browse Playlists + Songs.
class PlayerDrawer extends StatefulWidget {
  final AppController controller;
  final PlayerService player;
  final Song currentSong;
  final String? activePlaylistId;
  final ValueChanged<String?> onActivePlaylistChanged;

  const PlayerDrawer({
    super.key,
    required this.controller,
    required this.player,
    required this.currentSong,
    required this.activePlaylistId,
    required this.onActivePlaylistChanged,
  });

  @override
  State<PlayerDrawer> createState() => _PlayerDrawerState();
}

class _PlayerDrawerState extends State<PlayerDrawer> {
  int _selectedTab = 0; // 0 = Current Queue, 1 = Library & Playlists

  @override
  void initState() {
    super.initState();
    // Default to Queue if playing radio or if queue has items
    if (widget.player.queueSourceId == 'radio' || widget.player.queue.isNotEmpty) {
      _selectedTab = 0;
    } else {
      _selectedTab = 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final player = widget.player;
    final controller = widget.controller;

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Icon(
                    _selectedTab == 0 ? Icons.queue_music : Icons.library_music,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _selectedTab == 0 ? 'Playing Queue' : 'Library',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const Spacer(),
                  IconButton(
                    iconSize: 20,
                    tooltip: player.autoplay
                        ? 'Autoplay ON (Similar tracks)'
                        : 'Autoplay OFF',
                    icon: Icon(
                      Icons.auto_awesome_rounded,
                      color: player.autoplay
                          ? scheme.primary
                          : scheme.onSurfaceVariant.withValues(alpha: 0.4),
                    ),
                    onPressed: () => player.setAutoplay(!player.autoplay),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // Segmented Tab Switcher
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SegmentedButton<int>(
                segments: [
                  ButtonSegment(
                    value: 0,
                    label: Text('Queue (${player.queue.length})'),
                    icon: const Icon(Icons.queue_music, size: 16),
                  ),
                  const ButtonSegment(
                    value: 1,
                    label: Text('Library'),
                    icon: Icon(Icons.library_music, size: 16),
                  ),
                ],
                selected: {_selectedTab},
                onSelectionChanged: (newSet) {
                  setState(() => _selectedTab = newSet.first);
                },
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _selectedTab == 0
                  ? _buildQueueView(context, player, controller, scheme)
                  : _buildLibraryView(context, player, controller, scheme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueView(
    BuildContext context,
    PlayerService player,
    AppController controller,
    ColorScheme scheme,
  ) {
    final queue = player.queue;
    if (queue.isEmpty) {
      return const Center(
        child: Text('Queue is empty'),
      );
    }

    return ReorderableListView.builder(
      onReorder: (oldIdx, newIdx) => controller.reorderQueue(oldIdx, newIdx),
      itemCount: queue.length,
      itemBuilder: (context, i) {
        final song = queue[i];
        final isCurrent = i == player.queueIndex;
        final isStream = song.sourceDeviceId == 'stream';
        final isNetwork =
            song.artwork != null && song.artwork!.startsWith('http');

        return Dismissible(
          key: ValueKey('queue_item_${song.id}_$i'),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            color: scheme.error,
            child: const Icon(Icons.delete_outline, color: Colors.white),
          ),
          onDismissed: (_) => controller.removeFromQueue(i),
          child: ListTile(
            key: ValueKey('queue_tile_${song.id}_$i'),
            dense: true,
            leading: isNetwork
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      song.artwork!,
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          _iconPlaceholder(isCurrent, scheme),
                    ),
                  )
                : FutureBuilder<Uint8List?>(
                    initialData: ArtworkPalette.bytes(song),
                    future: ArtworkPalette.bytesAsync(song),
                    builder: (context, snapshot) {
                      final bytes =
                          snapshot.data ?? ArtworkPalette.bytes(song);
                      if (bytes == null || bytes.isEmpty) {
                        return _iconPlaceholder(isCurrent, scheme);
                      }
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.memory(
                          bytes,
                          width: 36,
                          height: 36,
                          cacheWidth: 72,
                          cacheHeight: 72,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              _iconPlaceholder(isCurrent, scheme),
                        ),
                      );
                    },
                  ),
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: isCurrent
                  ? TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.bold,
                    )
                  : null,
            ),
            subtitle: isStream
                ? Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Radio Stream',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                      if (StreamCacheManager.isStreamCachedSync(
                          song.id.replaceFirst('stream_', ''))) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.check_circle_outline_rounded,
                          size: 12,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          'Buffered',
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ],
                  )
                : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isStream)
                  IconButton(
                    icon: const Icon(Icons.download_rounded, size: 20),
                    tooltip: 'Save to library',
                    onPressed: () {
                      final appCtrl = context.read<AppController>();
                      appCtrl.saveStreamToLibrary(song);
                    },
                  ),
                ReorderableDragStartListener(
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.drag_handle,
                      size: 20,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ),
            onTap: () {
              player.playSong(
                song,
                queue: queue,
                sourceId: player.queueSourceId,
                sourceTitle: player.queueTitle,
              );
            },
          ),
        );
      },
    );
  }

  Widget _iconPlaceholder(bool isCurrent, ColorScheme scheme) {
    return Icon(
      isCurrent ? Icons.graphic_eq : Icons.music_note,
      color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
    );
  }

  Widget _buildLibraryView(
    BuildContext context,
    PlayerService player,
    AppController controller,
    ColorScheme scheme,
  ) {
    final playlists = controller.playlists;
    final playlist = playlistById(controller, widget.activePlaylistId);
    final String sectionTitle;
    final List<Song> songs;
    if (playlist != null) {
      sectionTitle = playlist.name;
      songs = songsForPlaylist(controller, playlist);
    } else if (player.queueSourceId == 'favorites') {
      sectionTitle = 'Favorites';
      songs = controller.getSortedSongs(
        controller.songs.where((s) => controller.isFavorite(s.id)).toList(),
      );
    } else {
      sectionTitle = 'All Songs';
      songs = controller.getSortedSongs(controller.songs);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _DrawerHeader(icon: Icons.queue_music, label: 'Playlists'),
        SizedBox(
          height: 120,
          child: playlists.isEmpty
              ? const Center(
                  child: Text('No playlists yet', style: TextStyle(fontSize: 12)),
                )
              : ListView.builder(
                  itemCount: playlists.length,
                  itemBuilder: (context, i) {
                    final pl = playlists[i];
                    final selected = pl.id == widget.activePlaylistId;
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.playlist_play,
                        color: selected ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                      title: Text(
                        pl.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${pl.songIds.length} songs'),
                      selected: selected,
                      onTap: () {
                        widget.onActivePlaylistChanged(pl.id);
                        controller.playPlaylist(pl);
                      },
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Icon(Icons.music_note, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sectionTitle,
                  style: Theme.of(context).textTheme.labelLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (playlist != null)
                TextButton(
                  onPressed: () => widget.onActivePlaylistChanged(null),
                  child: const Text('Show all'),
                ),
            ],
          ),
        ),
        Expanded(
          child: songs.isEmpty
              ? const Center(child: Text('No songs'))
              : ListView.builder(
                  itemCount: songs.length,
                  itemBuilder: (context, i) {
                    final s = songs[i];
                    final isCurrent = s.id == widget.currentSong.id;
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        isCurrent ? Icons.graphic_eq : Icons.music_note,
                        color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                      title: Text(
                        s.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: isCurrent
                            ? TextStyle(
                                color: scheme.primary,
                                fontWeight: FontWeight.w600,
                              )
                            : null,
                      ),
                      onTap: () {
                        player.playSong(
                          s,
                          queue: songs,
                          sourceId: playlist != null
                              ? 'playlist:'
                              : (player.queueSourceId == 'favorites'
                                  ? 'favorites'
                                  : 'library'),
                          sourceTitle: sectionTitle,
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _DrawerHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  const _DrawerHeader({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(label, style: Theme.of(context).textTheme.labelLarge),
        ],
      ),
    );
  }
}

Playlist? playlistById(AppController controller, String? id) {
  if (id == null) return null;
  for (final pl in controller.playlists) {
    if (pl.id == id) return pl;
  }
  return null;
}

List<Song> songsForPlaylist(AppController controller, Playlist playlist) => [
      for (final id in playlist.songIds)
        if (controller.library.findById(id) != null)
          controller.library.findById(id)!,
    ];
