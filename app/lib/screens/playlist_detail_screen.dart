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
import '../theme/tokens.dart';
import '../widgets/pear_app_bar.dart';
import '../widgets/tactile_button.dart';

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

  // The in-playlist filter (always shown on wide windows, behind
  // the Filter button on phones).
  final _filterController = TextEditingController();
  bool _showFilter = false;

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final playlist = controller.playlists
        .where((p) => p.id == widget.playlistId)
        .firstOrNull;

    // The playlist was deleted (e.g. from another flow) — leave.
    if (playlist == null) {
      return Scaffold(
        appBar: PearAppBar(title: const Text('Playlist'), showBackButton: true),
        body: PearEmptyState(
          icon: Icons.link_off_rounded,
          title: 'This playlist no longer exists',
          message: 'It may have been deleted on this device.',
          actionLabel: 'Back to library',
          onAction: () => Navigator.of(context).maybePop(),
        ),
      );
    }

    if (_optimisticIds != null) {
      final currentSet = playlist.songIds.toSet();
      final optSet = _optimisticIds!.toSet();
      if (currentSet.length != optSet.length ||
          !currentSet.containsAll(optSet)) {
        _optimisticIds = null;
      } else if (listEquals(_optimisticIds, playlist.songIds)) {
        _optimisticIds = null;
      }
    }

    final effectiveIds = _optimisticIds ?? playlist.songIds;

    final songs = <Song>[];
    for (final id in effectiveIds) {
      final s = controller.findSongById(id);
      if (s != null) songs.add(s);
    }

    return _buildPage(context, controller, playlist, songs);
  }

  Widget _row(
    AppController controller,
    Playlist playlist,
    List<Song> songs,
    int i, {
    required List<Song> queue,
    bool table = false,
  }) {
    final player = controller.player;
    final song = songs[i];
    final isCurrent = song.id == player.currentSong?.id;
    final isPlaying = isCurrent && player.playing;
    return _SongRow(
      key: ValueKey(song.id),
      song: song,
      isCurrent: isCurrent,
      isPlaying: isPlaying,
      index: i,
      table: table,
      onPlay: isPlaying
          ? () => controller.togglePlayback()
          : () => controller.player.playSong(
              song,
              queue: queue,
              sourceId: 'playlist:${playlist.id}',
              sourceTitle: playlist.name,
            ),
      onRemove: () => controller.removeSongFromPlaylist(playlist.id, song.id),
    );
  }

  /// A cover header with Play, Shuffle and a more menu, a filter inside the
  /// playlist, then the rows.
  Widget _buildPage(
    BuildContext context,
    AppController controller,
    Playlist playlist,
    List<Song> songs,
  ) {
    final theme = Theme.of(context);
    final q = _filterController.text.trim().toLowerCase();
    final shown = q.isEmpty
        ? songs
        : [
            for (final s in songs)
              if (s.lowerTitle.contains(q) || s.lowerArtist.contains(q)) s,
          ];

    void play() => controller.playPlaylist(playlist);
    void shuffle() {
      if (!controller.player.shuffle) controller.player.toggleShuffle();
      controller.playPlaylist(playlist);
    }

    // shortcut: no "Keep offline" action yet, there is no backend for
    // keeping a playlist downloaded; add it to this menu once there is.
    final menu = PearMenuButton<String>(
      tooltip: 'More',
      icon: Icons.more_vert_rounded,
      onSelected: (v) {
        switch (v) {
          case 'export':
            controller.exportPlaylistToM3u(playlist);
          case 'rename':
            _rename(context, controller, playlist);
          case 'delete':
            _confirmDelete(context, controller, playlist);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'export', child: Text('Export playlist (.m3u8)')),
        PopupMenuItem(value: 'rename', child: Text('Rename')),
        PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
      ],
    );

    final filterField = TextField(
      key: const ValueKey('playlist_filter'),
      controller: _filterController,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Filter this playlist',
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        suffixIcon: _filterController.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear filter',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () => setState(_filterController.clear),
              ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PearGlassTokens.r(8)),
        ),
      ),
    );

    return Scaffold(
      appBar: PearAppBar(title: const SizedBox.shrink(), showBackButton: true),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final inset = wide ? 24.0 : 16.0;
          final header = Padding(
            padding: EdgeInsets.fromLTRB(inset, 4, inset, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PlaylistHeader(
                  playlist: playlist,
                  songs: songs,
                  wide: wide,
                  onPlay: songs.isEmpty ? null : play,
                  onShuffle: songs.isEmpty ? null : shuffle,
                  menu: menu,
                ),
                if (!wide) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      // shortcut: a playlist only has its own (dragged)
                      // order; offer sort options here once the library has
                      // some to reuse.
                      Expanded(
                        child: Text(
                          'SORTED BY  CUSTOM ORDER',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            letterSpacing: 1.6,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => setState(() {
                          _showFilter = !_showFilter;
                          if (!_showFilter) _filterController.clear();
                        }),
                        icon: const Icon(Icons.tune_rounded, size: 18),
                        label: const Text('Filter'),
                      ),
                    ],
                  ),
                ],
                if (wide || _showFilter) ...[
                  SizedBox(height: wide ? 20 : 6),
                  filterField,
                ],
                if (wide && shown.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const _TableHeader(),
                ],
              ],
            ),
          );

          if (shown.isEmpty) {
            return ListView(
              padding: const EdgeInsets.only(bottom: 140),
              children: [
                header,
                songs.isEmpty
                    ? const _EmptyPlaylist()
                    : Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'No songs in this playlist match "$q"',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
              ],
            );
          }
          return ReorderableListView.builder(
            header: header,
            padding: EdgeInsets.fromLTRB(wide ? 14 : 0, 0, wide ? 14 : 0, 140),
            itemExtent: PearRow.extent,
            buildDefaultDragHandles: false,
            itemCount: shown.length,
            // A drag while filtered moves only the shown songs; _reorder
            // keeps the hidden ones where they are.
            onReorderItem: (oldIndex, newIndex) =>
                _reorder(controller, playlist, shown, oldIndex, newIndex),
            proxyDecorator: (child, index, animation) => Material(
              color: PearGlassTokens.angularPanel,
              elevation: 8,
              child: child,
            ),
            itemBuilder: (context, i) =>
                _row(controller, playlist, shown, i, queue: songs, table: wide),
          );
        },
      ),
    );
  }

  void _reorder(
    AppController controller,
    Playlist playlist,
    List<Song> songs,
    int oldIndex,
    int newIndex,
  ) {
    if (oldIndex < 0 ||
        oldIndex >= songs.length ||
        newIndex < 0 ||
        newIndex >= songs.length) {
      return;
    }
    final mutableSongs = List<Song>.from(songs);
    final moved = mutableSongs.removeAt(oldIndex);
    mutableSongs.insert(newIndex, moved);
    // Entries that cannot be resolved right now are not listed; they keep
    // their place instead of being dropped from the playlist by the reorder.
    final shown = songs.map((s) => s.id).toSet();
    final reordered = mutableSongs.map((s) => s.id).iterator;
    final ids = [
      for (final id in _optimisticIds ?? playlist.songIds)
        if (shown.contains(id) && reordered.moveNext()) reordered.current else id,
    ];
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
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => PearAlertDialog(
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
    } finally {
      controller_.dispose();
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AppController controller,
    Playlist playlist,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => PearAlertDialog(
        title: Text('Delete "${playlist.name}"?'),
        content: const Text(
          'The songs stay in your library; only the playlist is removed.',
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

  /// A wide window: Artist and Offline columns, like a table.
  final bool table;

  const _SongRow({
    super.key,
    required this.song,
    required this.isCurrent,
    required this.isPlaying,
    required this.index,
    required this.onPlay,
    required this.onRemove,
    this.table = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initialBytes =
        ArtworkPalette.cachedBytes(song) ??
        (song.artwork != null &&
                song.artwork!.isNotEmpty &&
                !song.artwork!.startsWith('http') &&
                song.artwork!.length < 65536
            ? ArtworkPalette.bytes(song)
            : null);
    final isNetwork = song.artwork != null && song.artwork!.startsWith('http');

    Widget artworkWidget;
    if (isNetwork) {
      artworkWidget = RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(PearGlassTokens.r(10)),
          child: Image.network(
            ArtworkService.optimizeArtworkUrl(song.artwork!),
            key: ValueKey('pl_net_${song.id}'),
            width: PearRow.cover,
            height: PearRow.cover,
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
          borderRadius: BorderRadius.circular(PearGlassTokens.r(10)),
          child: Image.memory(
            initialBytes,
            key: ValueKey('pl_mem_${song.id}'),
            width: PearRow.cover,
            height: PearRow.cover,
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
            if (bytes == null || bytes.isEmpty) {
              return _placeholder(theme.colorScheme);
            }
            return ClipRRect(
              borderRadius: BorderRadius.circular(PearGlassTokens.r(10)),
              child: Image.memory(
                bytes,
                key: ValueKey('pl_mem_${song.id}'),
                width: PearRow.cover,
                height: PearRow.cover,
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
        width: PearRow.cover,
        height: PearRow.cover,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(PearGlassTokens.r(10)),
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
        padding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: PearRow.gap,
        ),
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PearGlassTokens.r(14)),
          ),
          clipBehavior: Clip.antiAlias,
          child: GestureDetector(
            onSecondaryTapDown: (details) =>
                _showContextMenu(context, details.globalPosition),
            child: InkWell(
              mouseCursor: WidgetStateMouseCursor.clickable,
              onTap: () {
                TactileFeedback.click();
                onPlay();
              },
              hoverColor: Colors.white.withValues(alpha: 0.055),
              // Desktop rows: an instant press fill instead of the touch
              // ripple, which animates exactly while the song change re-seeds
              // the theme and read as laggy.
              splashFactory: NoSplash.splashFactory,
              highlightColor: Colors.white.withValues(alpha: 0.06),
              child: Ink(
                // The song lists' row body, in whatever look is in use.
                decoration: PearRowLook.body(context, current: isCurrent),
                child: SizedBox(
                  height: PearRow.content,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 14, right: 6),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            // Wide rows move the size into a right-aligned column
                            // so the row reads like a table on desktop.
                            final wideRow = constraints.maxWidth >= 620;
                            final tableRow = table && wideRow;
                            final muted = theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 12.5,
                            );
                            return Row(
                              children: [
                                artworkWidget,
                                const SizedBox(width: 12),
                                Expanded(
                                  flex: tableRow ? 2 : 1,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        song.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                              color: isCurrent
                                                  ? theme.colorScheme.primary
                                                  : null,
                                            ),
                                      ),
                                      const SizedBox(height: 3),
                                      if (!wideRow)
                                        Text(
                                          song.sizeLabel,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                                fontSize: 12.5,
                                              ),
                                        ),
                                    ],
                                  ),
                                ),
                                if (tableRow) ...[
                                  Expanded(
                                    child: Text(
                                      song.artist ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: muted,
                                    ),
                                  ),
                                  SizedBox(
                                    width: _TableHeader.offlineWidth,
                                    child: _OfflineMark(song: song),
                                  ),
                                  SizedBox(
                                    width: _TableHeader.sizeWidth,
                                    child: Text(
                                      song.sizeLabel,
                                      maxLines: 1,
                                      textAlign: TextAlign.right,
                                      style: muted,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ] else if (wideRow)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 18),
                                    child: Text(
                                      song.sizeLabel,
                                      maxLines: 1,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                            fontSize: 12.5,
                                          ),
                                    ),
                                  ),
                                TactileIconButton(
                                  tooltip: 'Remove from playlist',
                                  icon: Icon(
                                    Icons.remove_circle_outline_rounded,
                                    size: 19,
                                    color: theme.colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.6),
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                  onPressed: onRemove,
                                ),
                                ReorderableDragStartListener(
                                  index: index,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 8,
                                    ),
                                    child: Icon(
                                      Icons.drag_handle_rounded,
                                      size: 20,
                                      color: theme.colorScheme.onSurfaceVariant
                                          .withValues(alpha: 0.5),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Right-click context menu for a playlist row.
  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final controller = context.read<AppController>();
    final selected = await showPearContextMenu(context, position, [
      const PearMenuEntry('play', 'Play'),
      const PearMenuEntry('play_next', 'Play next'),
      const PearMenuEntry(
        'add_to_queue',
        'Add to queue',
      ),
      PearMenuEntry(
        'remove',
        'Remove from playlist',
        color: Theme.of(context).colorScheme.error,
        separatorBefore: true,
      ),
    ]);
    if (!context.mounted || selected == null) return;
    switch (selected) {
      case 'play':
        onPlay();
      case 'play_next':
        controller.playNext(song);
      case 'add_to_queue':
        controller.addToQueue(song);
      case 'remove':
        onRemove();
    }
  }

  Widget _placeholder(ColorScheme scheme) {
    return Container(
      width: PearRow.cover,
      height: PearRow.cover,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(PearGlassTokens.r(10)),
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

/// "12 songs · 1 hr 4 min"; the length is left off while no song has one.
String playlistSummary(List<Song> songs) {
  final count = '${songs.length} song${songs.length == 1 ? '' : 's'}';
  final total = Duration(
    milliseconds: songs.fold<int>(0, (t, s) => t + (s.durationMs ?? 0)),
  );
  final h = total.inHours;
  final m = total.inMinutes % 60;
  final length = [if (h > 0) '$h hr', if (m > 0) '$m min'].join(' ');
  return length.isEmpty ? count : '$count · $length';
}

/// Column labels over the wide table rows, lined up with [_SongRow]'s
/// columns.
class _TableHeader extends StatelessWidget {
  const _TableHeader();

  static const double offlineWidth = 96;
  static const double sizeWidth = 72;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 10.5,
      letterSpacing: 2,
      fontWeight: FontWeight.w600,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    // The rows sit 14 further in than this header on the left (list and
    // row padding) and 6 on the right; the 64 is the remove and drag
    // buttons.
    return Container(
      padding: EdgeInsets.fromLTRB(14 + PearRow.cover + 12, 0, 6 + 64 + 8, 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
        ),
      ),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text('TITLE', style: style)),
          Expanded(child: Text('ARTIST', style: style)),
          SizedBox(width: offlineWidth, child: Text('OFFLINE', style: style)),
          SizedBox(
            width: sizeWidth,
            child: Text('SIZE', textAlign: TextAlign.right, style: style),
          ),
        ],
      ),
    );
  }
}

/// SAVED for a song that is a file on this device, ONLINE for one that
/// plays from the internet.
///
/// shortcut: an online song whose downloaded copy is also in the library
/// still reads ONLINE; look the copy up by video id if that confuses.
class _OfflineMark extends StatelessWidget {
  const _OfflineMark({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final online = song.sourceDeviceId == 'stream';
    final color = online
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Icon(
          online ? Icons.cloud_outlined : Icons.download_done_rounded,
          size: 15,
          color: color,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            online ? 'ONLINE' : 'SAVED',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, letterSpacing: 1.4, color: color),
          ),
        ),
      ],
    );
  }
}

class _PlaylistHeader extends StatelessWidget {
  final Playlist playlist;
  final List<Song> songs;
  final bool wide;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final Widget menu;

  const _PlaylistHeader({
    required this.playlist,
    required this.songs,
    required this.wide,
    required this.onPlay,
    required this.onShuffle,
    required this.menu,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final square = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(PearGlassTokens.r(8)),
    );
    final playButton = wide
        ? FilledButton.icon(
            onPressed: onPlay,
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              minimumSize: const Size(120, 48),
              shape: square,
            ),
            icon: const Icon(Icons.play_arrow_rounded, size: 24),
            label: const Text(
              'PLAY',
              style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 2),
            ),
          )
        : IconButton.filled(
            tooltip: 'Play',
            onPressed: onPlay,
            style: IconButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              minimumSize: const Size(48, 48),
              shape: square,
            ),
            icon: const Icon(Icons.play_arrow_rounded, size: 26),
          );
    final buttons = Row(
      children: [
        playButton,
        const SizedBox(width: 10),
        IconButton.outlined(
          tooltip: 'Shuffle',
          onPressed: onShuffle,
          style: IconButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: square,
            side: BorderSide(
              color: Colors.white.withValues(alpha: PearGlassTokens.edge * 2),
            ),
          ),
          icon: const Icon(Icons.shuffle_rounded, size: 20),
        ),
        if (wide) const SizedBox(width: 6) else const Spacer(),
        menu,
      ],
    );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              'PLAYLIST',
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 2.4,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        SizedBox(height: wide ? 10 : 6),
        Text(
          playlist.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: (wide
                  ? theme.textTheme.displaySmall
                  : theme.textTheme.headlineSmall)
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        SizedBox(height: wide ? 10 : 6),
        Text(
          playlistSummary(songs),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (wide) ...[const SizedBox(height: 20), buttons],
      ],
    );

    final cover = _PlaylistCover(
      song: songs.firstOrNull,
      size: wide ? 200 : 132,
    );
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [cover, const SizedBox(width: 28), Expanded(child: info)],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [cover, const SizedBox(width: 16), Expanded(child: info)],
        ),
        const SizedBox(height: 14),
        buttons,
      ],
    );
  }
}

/// The playlist's cover: its first song's artwork in a Graphite cut-corner
/// frame, or a plain panel when there is none.
class _PlaylistCover extends StatelessWidget {
  final Song? song;
  final double size;

  const _PlaylistCover({required this.song, required this.size});

  @override
  Widget build(BuildContext context) {
    final shape = PearGlassTokens.angularShape();
    final blank = Container(
      key: const ValueKey('playlist_cover_blank'),
      decoration: ShapeDecoration(
        color: PearGlassTokens.angularPanel,
        shape: shape,
      ),
      child: Icon(
        Icons.queue_music_rounded,
        size: size * 0.3,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
    final s = song;
    final cacheWidth = (size * 2).round();
    Widget image;
    if (s == null) {
      image = blank;
    } else if (s.artwork?.startsWith('http') ?? false) {
      image = Image.network(
        ArtworkService.optimizeArtworkUrl(s.artwork!),
        cacheWidth: cacheWidth,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => blank,
      );
    } else {
      image = FutureBuilder<Uint8List?>(
        key: ValueKey('playlist_cover_${s.id}'),
        initialData: ArtworkPalette.cachedBytes(s),
        future: ArtworkPalette.bytesAsync(s),
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes == null || bytes.isEmpty) return blank;
          return Image.memory(
            bytes,
            cacheWidth: cacheWidth,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => blank,
          );
        },
      );
    }
    return SizedBox.square(
      dimension: size,
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: image,
      ),
    );
  }
}

class _EmptyPlaylist extends StatelessWidget {
  const _EmptyPlaylist();

  @override
  Widget build(BuildContext context) {
    // shortcut: no Add songs button, songs come in from the library's menu.
    return const PearEmptyState(
      icon: Icons.music_off_rounded,
      title: 'This playlist is empty',
      message: 'Long-press a song in your library to add it here.',
    );
  }
}
