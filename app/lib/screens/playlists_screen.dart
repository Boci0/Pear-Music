import '../widgets/pear_empty_state.dart';
import '../widgets/pear_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/artwork_service.dart';
import '../theme/glass.dart';
import '../widgets/import_export_sheet.dart';
import '../widgets/pear_app_bar.dart';
import '../widgets/pear_popup.dart';
import '../widgets/pear_page_route.dart';
import '../widgets/player_bar.dart';
import '../widgets/tactile_button.dart';
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
      appBar: PearAppBar(
        label: 'Playlists',
        actions: [
          TactileIconButton(
            tooltip: 'Import playlists',
            icon: const Icon(Icons.playlist_add_rounded),
            onPressed: () => showPlaylistImportDialog(context, controller),
          ),
          TactileIconButton(
            tooltip: 'New playlist',
            icon: const Icon(Icons.add),
            onPressed: () => createPlaylist(context, controller),
          ),
        ],
      ),
      // If pushed as a separate route, show the mini player bar. When embedded
      // inside HomeShell, HomeShell's own PlayerBar handles playback controls.
      bottomNavigationBar: showPlayerBar ? const PlayerBar() : null,
      body: playlists.isEmpty
          ? _EmptyPlaylists(
              onCreate: () => createPlaylist(context, controller),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                // Wide windows get a multi-column card grid; phones keep the
                // single-column list.
                final columns = (constraints.maxWidth / 420).floor().clamp(
                  1,
                  3,
                );

                Widget tileAt(int i) =>
                    playlistTile(context, controller, playlists[i]);

                Widget itemAt(int i) => i < playlists.length
                    ? tileAt(i)
                    : newPlaylistTile(context, controller);

                if (columns <= 1) {
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
                    itemExtent: 72.0,
                    itemCount: playlists.length + 1,
                    itemBuilder: (context, i) => itemAt(i),
                  );
                }
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisExtent: 72,
                    crossAxisSpacing: 4,
                  ),
                  itemCount: playlists.length + 1,
                  itemBuilder: (context, i) => itemAt(i),
                );
              },
            ),
    );
  }

  /// One playlist row with play, rename and delete, as this tab lists it.
  /// The Library shows the same rows.
  static Widget playlistTile(
    BuildContext context,
    AppController controller,
    Playlist pl,
  ) {
    final currentSongId = controller.player.currentSong?.id;
    final isCurrentPlaylist =
        controller.player.queueSourceId == 'playlist:${pl.id}' ||
        (currentSongId != null && pl.songIds.contains(currentSongId));
    final isPlayingThisPlaylist =
        isCurrentPlaylist && controller.player.playing;

    return _PlaylistTile(
      key: ValueKey(pl.id),
      playlist: pl,
      isActive: isCurrentPlaylist,
      isPlaying: isPlayingThisPlaylist,
      onPlay: () {
        if (isPlayingThisPlaylist) {
          controller.player.pause();
        } else if (isCurrentPlaylist && controller.player.currentSong != null) {
          controller.player.resume();
        } else {
          controller.playPlaylist(pl);
        }
      },
      onRename: () => _renamePlaylist(context, controller, pl),
      onDelete: () => _confirmDelete(context, controller, pl),
    );
  }

  /// The "New playlist" card that ends the list.
  static Widget newPlaylistTile(
    BuildContext context,
    AppController controller,
  ) => _NewPlaylistTile(onTap: () => createPlaylist(context, controller));

  static Future<void> createPlaylist(
    BuildContext context,
    AppController controller,
  ) async {
    final nameController = TextEditingController();
    try {
      final name = await showDialog<String>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) => PearAlertDialog(
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
    } finally {
      nameController.dispose();
    }
  }

  static Future<void> _confirmDelete(
    BuildContext context,
    AppController controller,
    Playlist playlist,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => PearAlertDialog(
        title: Text('Delete "${playlist.name}"?'),
        content: const Text(
          'The songs stay in your library; only the playlist '
          'is removed.',
        ),
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

  static Future<void> _renamePlaylist(
    BuildContext context,
    AppController controller,
    Playlist playlist,
  ) async {
    final nameController = TextEditingController(text: playlist.name);
    try {
      final name = await showDialog<String>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) => PearAlertDialog(
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
    } finally {
      nameController.dispose();
    }
  }
}

/// Trailing "New playlist" card at the end of the playlist list or grid.
class _NewPlaylistTile extends StatelessWidget {
  final VoidCallback onTap;

  const _NewPlaylistTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1.5),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(PearGlassTokens.r(16)),
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: onTap,
          borderRadius: BorderRadius.circular(PearGlassTokens.r(16)),
          hoverColor: Colors.white.withValues(alpha: 0.055),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(PearGlassTokens.r(16)),
              color: Colors.white.withValues(
                alpha: PearGlassTokens.cardFill,
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(
                  Icons.add_rounded,
                  size: 22,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Text(
                  'New playlist',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens a playlist's options sheet (the control port's /sheet check).
Future<void> showPlaylistOptionsFor(BuildContext context, Playlist playlist) =>
    _PlaylistTile(
      playlist: playlist,
      isActive: false,
      onPlay: () {},
      onRename: () {},
      onDelete: () {},
    )._showMenu(context);

class _PlaylistTile extends StatelessWidget {
  final Playlist playlist;
  final bool isActive;
  final bool isPlaying;
  final VoidCallback onPlay;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _PlaylistTile({
    super.key,
    required this.playlist,
    required this.isActive,
    this.isPlaying = false,
    required this.onPlay,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = context.read<AppController>();

    final firstSong = PlaylistArtwork.firstSongOf(controller, playlist);

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.0),
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PearGlassTokens.r(14)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            mouseCursor: WidgetStateMouseCursor.clickable,
            onTap: () {
              TactileFeedback.click();
              Navigator.of(context).push(
                PearPageRoute(
                  builder: (_) => PlaylistDetailScreen(playlistId: playlist.id),
                  // Lets the wide rail light this playlist.
                  settings: RouteSettings(name: playlist.id),
                ),
              );
            },
            hoverColor: Colors.white.withValues(alpha: 0.055),
            child: Ink(
              // A square graphite tile with a thin edge.
              decoration: BoxDecoration(
                color: isActive
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.white.withValues(alpha: 0.025),
                border: Border.all(
                  color: isActive
                      ? theme.colorScheme.primary
                      : PearGlassTokens.cardRim,
                ),
              ),
              child: SizedBox(
                height: 64,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 14, right: 8),
                      child: Row(
                        children: [
                          PlaylistArtwork(
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
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: -0.1,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isActive
                                        ? theme.colorScheme.primary.withValues(
                                            alpha: 0.15,
                                          )
                                        : Colors.white.withValues(alpha: 0.05),
                                    borderRadius: BorderRadius.circular(PearGlassTokens.r(10)),
                                  ),
                                  child: Text(
                                    '${playlist.songIds.length} track${playlist.songIds.length == 1 ? '' : 's'}',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: isActive
                                          ? theme.colorScheme.primary
                                          : theme.colorScheme.onSurfaceVariant
                                                .withValues(alpha: 0.8),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TactileIconButton(
                            tooltip: isPlaying
                                ? 'Pause'
                                : (isActive ? 'Resume' : 'Play all'),
                            icon: Icon(
                              isPlaying
                                  ? Icons.pause_circle_filled_rounded
                                  : Icons.play_circle_fill_rounded,
                              color: theme.colorScheme.primary,
                              size: 28,
                            ),
                            onPressed: onPlay,
                          ),
                          Builder(
                            builder: (menuContext) => TactileIconButton(
                              icon: Icon(
                                Icons.more_vert_rounded,
                                size: 20,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              tooltip: 'Playlist options',
                              onPressed: () => _showMenu(
                                context,
                                anchor: popupAnchorBelowRight(menuContext),
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

  Future<void> _showMenu(BuildContext context, {Offset? anchor}) async {
    final controller = context.read<AppController>();
    final action = await showPearPopup<String>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      maxWidth: 360,
      anchor: anchor,
      anchorAlignRight: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // shortcut: no cover, total time or Keep offline switch on the
              // board's header; playlists have none of that yet.
              PearSheetTitle(
                playlist.name,
                subtitle:
                    '${playlist.songIds.length} track${playlist.songIds.length == 1 ? '' : 's'}',
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: PearSheetButton(
                        label: 'Play all',
                        icon: Icons.play_arrow_rounded,
                        filled: true,
                        onTap: () => Navigator.pop(ctx, 'play'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: PearSheetButton(
                        label: 'Shuffle',
                        icon: Icons.shuffle_rounded,
                        onTap: () => Navigator.pop(ctx, 'shuffle'),
                      ),
                    ),
                  ],
                ),
              ),
              PearSheetRow(
                label: 'Rename',
                onTap: () => Navigator.pop(ctx, 'rename'),
              ),
              PearSheetRow(
                label: 'Export as .m3u8',
                onTap: () => Navigator.pop(ctx, 'export'),
              ),
              PearSheetRow(
                label: 'Delete playlist',
                danger: true,
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
              const SizedBox(height: 8),
            ],
          ),
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
    } else if (action == 'export') {
      controller.exportPlaylistToM3u(playlist);
    } else if (action == 'delete') {
      onDelete();
    }
  }
}

/// A playlist's thumbnail: its first song's cover, or the playlist icon
/// when it has none. Shared by the Playlists list and the wide rail.
class PlaylistArtwork extends StatelessWidget {
  final Song? firstSong;
  final bool isActive;
  final double size;

  /// Corner radius; null is the list's rounded 10.
  final double? radius;

  const PlaylistArtwork({
    super.key,
    required this.firstSong,
    this.isActive = false,
    this.size = 46,
    this.radius,
  });

  /// The playlist's first song still in the library, for its cover.
  static Song? firstSongOf(AppController controller, Playlist playlist) {
    for (final id in playlist.songIds) {
      final s = controller.findSongById(id);
      if (s != null) return s;
    }
    return null;
  }

  BorderRadius get _corners =>
      BorderRadius.circular(radius ?? PearGlassTokens.r(10));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget content;
    if (firstSong == null) {
      content = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: _corners,
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        ),
        child: Icon(
          Icons.queue_music_rounded,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          size: size * 0.48,
        ),
      );
    } else {
      final song = firstSong!;
      final bytes =
          ArtworkPalette.cachedBytes(song) ??
          (song.artwork != null &&
                  song.artwork!.isNotEmpty &&
                  !song.artwork!.startsWith('http') &&
                  song.artwork!.length < 65536
              ? ArtworkPalette.bytes(song)
              : null);
      final isNetwork =
          song.artwork != null && song.artwork!.startsWith('http');
      if (isNetwork) {
        content = ClipRRect(
          borderRadius: _corners,
          child: Image.network(
            ArtworkService.optimizeArtworkUrl(song.artwork!),
            key: ValueKey('pl_net_${song.id}'),
            width: size,
            height: size,
            cacheWidth: (size * 2).round(),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _fallback(scheme),
          ),
        );
      } else if (bytes != null && bytes.isNotEmpty) {
        content = ClipRRect(
          borderRadius: _corners,
          child: Image.memory(
            bytes,
            key: ValueKey('pl_mem_${song.id}'),
            width: size,
            height: size,
            cacheWidth: (size * 2).round(),
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
                borderRadius: _corners,
                child: Image.memory(
                  b,
                  key: ValueKey('pl_mem_${song.id}'),
                  width: size,
                  height: size,
                  cacheWidth: (size * 2).round(),
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
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: _corners,
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
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: _corners,
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
        size: size * 0.48,
      ),
    );
  }
}

class _EmptyPlaylists extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptyPlaylists({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    // shortcut: only New playlist here, Import lives in the Import and export
    // sheet; PearEmptyState takes one action.
    return PearEmptyState(
      icon: Icons.queue_music_rounded,
      title: 'No playlists created yet',
      message: 'Make one, or bring playlists in from another app.',
      actionLabel: 'New playlist',
      onAction: onCreate,
    );
  }
}
