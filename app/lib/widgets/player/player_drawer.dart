import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/artwork_service.dart';
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
  final ScrollController _drawerQueueController = ScrollController();
  int _selectedTab = 0; // 0 = Current Queue, 1 = Library & Playlists

  @override
  void initState() {
    super.initState();
    // Default to Queue if playing radio or if queue has items
    if (widget.player.queueSourceId == 'radio' ||
        widget.player.queue.isNotEmpty) {
      _selectedTab = 0;
    } else {
      _selectedTab = 1;
    }
  }

  @override
  void dispose() {
    _drawerQueueController.dispose();
    super.dispose();
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
                  Expanded(
                    child: Text(
                      _selectedTab == 0 ? 'Playing Queue' : 'Library',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  IconButton(
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    tooltip: 'Reroll seed (reroll upcoming recommendations)',
                    icon: Icon(Icons.casino_outlined, color: scheme.primary),
                    onPressed: () => player.rerollUpcomingQueue(),
                  ),
                  IconButton(
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
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
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
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
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final queue = player.queue;
        // Content-stable, duplicate-safe keys: element state survives
        // reroll, removal and reorder.
        final keys = <String>[];
        final occurrences = <String, int>{};
        for (final s in queue) {
          final n = occurrences[s.id] ?? 0;
          occurrences[s.id] = n + 1;
          keys.add(n == 0 ? s.id : '${s.id}#${n + 1}');
        }
        if (queue.isEmpty) {
          return const Center(child: Text('Queue is empty'));
        }

        return ListView.builder(
          // Fixed extent (dense two-line ListTile): O(1) scroll geometry.
          itemExtent: 64.0,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          controller: _drawerQueueController,
          itemCount: queue.length,
          findChildIndexCallback: (Key key) {
            final valueKey = key as ValueKey<String>?;
            if (valueKey == null) return null;
            final index = keys.indexWhere(
              (k) => 'drawer_queue_$k' == valueKey.value,
            );
            return index >= 0 ? index : null;
          },
          itemBuilder: (context, i) {
            final song = queue[i];
            final isCurrent = i == player.queueIndex;
            final isStream = song.sourceDeviceId == 'stream';
            final isUpcoming = i > player.queueIndex;
            final isLocked = player.isSongLocked(song.id);
            final isNetwork =
                song.artwork != null && song.artwork!.startsWith('http');

            final artworkWidget = isNetwork
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      ArtworkService.optimizeArtworkUrl(song.artwork!),
                      width: 36,
                      height: 36,
                      cacheWidth: 108,
                      cacheHeight: 108,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
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
                          cacheWidth: 108,
                          cacheHeight: 108,
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          errorBuilder: (_, _, _) =>
                              _iconPlaceholder(isCurrent, scheme),
                        ),
                      );
                    },
                  );

            return RepaintBoundary(
              // Per-row repaint isolation: artwork decode and lock changes do
              // not repaint neighbouring rows.
              key: ValueKey('drawer_queue_${keys[i]}'),
              child: ListTile(
                dense: true,
                tileColor: isCurrent
                    ? scheme.primaryContainer.withValues(alpha: 0.35)
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: isCurrent
                      ? BorderSide(
                          color: scheme.primary.withValues(alpha: 0.5),
                          width: 1,
                        )
                      : BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                leading: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 20,
                      child: isCurrent
                          ? Icon(
                              Icons.graphic_eq_rounded,
                              color: scheme.primary,
                              size: 16,
                            )
                          : Text(
                              '${i + 1}',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant
                                    .withValues(alpha: 0.6),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                    const SizedBox(width: 6),
                    artworkWidget,
                  ],
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
                subtitle: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        isStream
                            ? 'Radio Stream'
                            : (song.sourceDeviceId == null
                                  ? 'Local track'
                                  : 'Shared'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: isCurrent
                              ? scheme.primary.withValues(alpha: 0.8)
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (isStream &&
                        StreamCacheManager.isStreamCachedSync(
                          song.id.replaceFirst('stream_', ''),
                        )) ...[
                      const SizedBox(width: 6),
                      const Tooltip(
                        message: 'Cached',
                        child: Icon(
                          Icons.check_circle_rounded,
                          size: 13,
                          color: Color(0xFF81C784),
                        ),
                      ),
                    ],
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isLocked)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        icon: Icon(
                          Icons.lock_rounded,
                          size: 16,
                          color: scheme.primary,
                        ),
                        tooltip: 'Locked (tap to unlock)',
                        onPressed: () => player.toggleSongLock(song.id),
                      ),
                    PopupMenuButton<String>(
                      icon: Icon(
                        Icons.more_vert_rounded,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      onSelected: (action) {
                        if (action == 'lock') {
                          player.toggleSongLock(song.id);
                        } else if (action == 'save') {
                          context.read<AppController>().saveStreamToLibrary(
                            song,
                          );
                        } else if (action == 'remove') {
                          controller.removeFromQueue(i);
                        }
                      },
                      itemBuilder: (context) => [
                        if (isUpcoming)
                          PopupMenuItem(
                            value: 'lock',
                            child: Row(
                              children: [
                                Icon(
                                  isLocked
                                      ? Icons.lock_open_rounded
                                      : Icons.lock_rounded,
                                  size: 18,
                                  color: isLocked ? null : scheme.primary,
                                ),
                                const SizedBox(width: 10),
                                Text(isLocked ? 'Unlock track' : 'Lock track'),
                              ],
                            ),
                          ),
                        if (isStream)
                          const PopupMenuItem(
                            value: 'save',
                            child: Row(
                              children: [
                                Icon(Icons.download_rounded, size: 18),
                                SizedBox(width: 10),
                                Text('Save to library'),
                              ],
                            ),
                          ),
                        const PopupMenuItem(
                          value: 'remove',
                          child: Row(
                            children: [
                              Icon(Icons.close_rounded, size: 18),
                              SizedBox(width: 10),
                              Text('Remove from queue'),
                            ],
                          ),
                        ),
                      ],
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
                  child: Text(
                    'No playlists yet',
                    style: TextStyle(fontSize: 12),
                  ),
                )
              : ListView.builder(
                  itemCount: playlists.length,
                  itemBuilder: (context, i) {
                    final pl = playlists[i];
                    final selected = pl.id == widget.activePlaylistId;
                    return RepaintBoundary(
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.playlist_play,
                          color: selected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
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
                      ),
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
                  // Fixed extent (dense one-line ListTile): O(1) scroll geometry.
                  itemExtent: 48.0,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  itemCount: songs.length,
                  itemBuilder: (context, i) {
                    final s = songs[i];
                    final isCurrent = s.id == widget.currentSong.id;
                    return RepaintBoundary(
                      child: ListTile(
                        dense: true,
                        tileColor: isCurrent
                            ? scheme.primaryContainer.withValues(alpha: 0.35)
                            : null,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: isCurrent
                              ? BorderSide(
                                  color: scheme.primary.withValues(alpha: 0.5),
                                  width: 1,
                                )
                              : BorderSide.none,
                        ),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 12),
                        leading: Icon(
                          isCurrent
                              ? Icons.graphic_eq_rounded
                              : Icons.music_note,
                          color: isCurrent
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                        title: Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: isCurrent
                              ? TextStyle(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.bold,
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
                      ),
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
