import 'package:flutter/material.dart';

import '../../controllers/app_controller.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/player_service.dart';

/// Mobile drawer: browse Playlists + Songs from the player screen.
class PlayerDrawer extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playlists = controller.playlists;
    final playlist = playlistById(controller, activePlaylistId);
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

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.library_music, color: scheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    'Library',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            _DrawerHeader(icon: Icons.queue_music, label: 'Playlists'),
            SizedBox(
              height: 140,
              child: playlists.isEmpty
                  ? const Center(
                      child: Text('No playlists yet',
                          style: TextStyle(fontSize: 12)),
                    )
                  : ListView.builder(
                      itemCount: playlists.length,
                      itemBuilder: (context, i) {
                        final pl = playlists[i];
                        final selected = pl.id == activePlaylistId;
                        return ListTile(
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
                            onActivePlaylistChanged(pl.id);
                            controller.playPlaylist(pl);
                            Navigator.of(context).pop();
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
                  Icon(Icons.music_note,
                      size: 16, color: scheme.onSurfaceVariant),
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
                      onPressed: () => onActivePlaylistChanged(null),
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
                        final isCurrent = s.id == currentSong.id;
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            isCurrent ? Icons.graphic_eq : Icons.music_note,
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
                            Navigator.of(context).pop();
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
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
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
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