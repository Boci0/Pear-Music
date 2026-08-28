import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/player_service.dart';
import '../../services/recommendation_service.dart';
import '../../services/stream_cache_manager.dart';
import 'player_artwork.dart';
import 'player_controls.dart';

/// Wide (desktop) layout: Left hero showcase + Right interactive queue &
/// controls panel.
class PlayerWideBody extends StatefulWidget {
  final AppController controller;
  final PlayerService player;
  final Song song;
  final Duration duration;
  final Color accent;
  final String? activePlaylistId;
  final ValueChanged<String?> onActivePlaylistChanged;

  const PlayerWideBody({
    super.key,
    required this.controller,
    required this.player,
    required this.song,
    required this.duration,
    required this.accent,
    required this.activePlaylistId,
    required this.onActivePlaylistChanged,
  });

  @override
  State<PlayerWideBody> createState() => _PlayerWideBodyState();
}

class _PlayerWideBodyState extends State<PlayerWideBody> {
  int _selectedTab = 0; // 0 = Queue, 1 = Playlists

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = widget.controller;
    final player = widget.player;
    final song = widget.song;
    final duration = widget.duration;
    final accent = widget.accent;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1300),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left Hero Section (Artwork, Title, Artist, Badges)
            Expanded(
              flex: 5,
              child: Card(
                elevation: 0,
                color: scheme.surfaceContainerLow.withValues(alpha: 0.6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.2),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final artSize = (constraints.maxHeight * 0.85)
                                .clamp(180.0, 380.0);
                            return Center(
                              child: PlayerArtworkHero(
                                song: song,
                                size: artSize,
                                artwork: ArtworkPalette.bytes(song),
                                accent: accent,
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 24),
                      PlayerSongInfo(song: song),
                      if (player.queueTitle != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Text(
                            'Playing from ${player.queueTitle}',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 20),
            // Right Section (Interactive Queue / Playlists & Docked Controls)
            Expanded(
              flex: 6,
              child: Card(
                elevation: 0,
                color: scheme.surfaceContainerLow.withValues(alpha: 0.6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.2),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header Navigation
                      Row(
                        children: [
                          SegmentedButton<int>(
                            segments: [
                              ButtonSegment(
                                value: 0,
                                icon: const Icon(
                                  Icons.queue_music_rounded,
                                  size: 18,
                                ),
                                label: Text('Queue (${player.queue.length})'),
                              ),
                              ButtonSegment(
                                value: 1,
                                icon: const Icon(
                                  Icons.playlist_play_rounded,
                                  size: 18,
                                ),
                                label: Text(
                                  'Playlists (${controller.playlists.length})',
                                ),
                              ),
                            ],
                            selected: {_selectedTab},
                            onSelectionChanged: (set) =>
                                setState(() => _selectedTab = set.first),
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                          const Spacer(),
                          if (_selectedTab == 0) ...[
                            IconButton(
                              iconSize: 18,
                              tooltip:
                                  'Reroll seed (reroll upcoming recommendations)',
                              icon: Icon(
                                Icons.casino_outlined,
                                color: scheme.primary,
                              ),
                              onPressed: () => player.rerollUpcomingQueue(),
                            ),
                            IconButton(
                              iconSize: 18,
                              tooltip: player.autoplay
                                  ? 'Autoplay ON (Similar tracks)'
                                  : 'Autoplay OFF',
                              icon: Icon(
                                Icons.auto_awesome_rounded,
                                color: player.autoplay
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant.withValues(
                                        alpha: 0.4,
                                      ),
                              ),
                              onPressed: () =>
                                  player.setAutoplay(!player.autoplay),
                            ),
                            if (player.queue.length > 1)
                              TextButton.icon(
                                onPressed: () => player.toggleShuffle(),
                                icon: Icon(
                                  Icons.shuffle_rounded,
                                  size: 16,
                                  color: player.shuffle
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                                label: Text(
                                  player.shuffle ? 'Shuffled' : 'Shuffle',
                                  style: TextStyle(
                                    color: player.shuffle
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 14),
                      // Tab Body
                      Expanded(
                        child: _selectedTab == 0
                            ? PlayerWideQueueView(
                                player: player,
                                currentSong: song,
                                scheme: scheme,
                              )
                            : PlayerWidePlaylistsView(
                                controller: controller,
                                activePlaylistId: widget.activePlaylistId,
                                onSelect: (pl) {
                                  widget.onActivePlaylistChanged(pl.id);
                                  controller.playPlaylist(pl);
                                },
                                scheme: scheme,
                              ),
                      ),
                      const SizedBox(height: 14),
                      const Divider(height: 1),
                      const SizedBox(height: 14),
                      // Docked Controls
                      PlayerSeekBar(player: player, duration: duration),
                      const SizedBox(height: 10),
                      PlayerTransport(player: player, controller: controller),
                      const SizedBox(height: 10),
                      const PlayerVolumeRow(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlayerWideQueueView extends StatefulWidget {
  final PlayerService player;
  final Song currentSong;
  final ColorScheme scheme;
  const PlayerWideQueueView({
    super.key,
    required this.player,
    required this.currentSong,
    required this.scheme,
  });

  @override
  State<PlayerWideQueueView> createState() => _PlayerWideQueueViewState();
}

class _PlayerWideQueueViewState extends State<PlayerWideQueueView> {
  final ScrollController _scrollController = ScrollController();
  String? _lastScrolledSongId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToCurrent(force: true);
    });
  }

  @override
  void didUpdateWidget(covariant PlayerWideQueueView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentSong.id != widget.currentSong.id) {
      _scrollToCurrent();
    }
  }

  void _scrollToCurrent({bool force = false}) {
    if (!_scrollController.hasClients) return;
    if (!force && _lastScrolledSongId == widget.currentSong.id) return;
    _lastScrolledSongId = widget.currentSong.id;

    final queue = widget.player.queue;
    final idx = queue.indexWhere((s) => s.id == widget.currentSong.id);
    if (idx >= 0) {
      final targetOffset = (idx * 56.0 - 80.0).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      final diff = (_scrollController.offset - targetOffset).abs();
      if (diff > 250) {
        _scrollController.jumpTo(targetOffset);
      } else if (diff > 2) {
        _scrollController.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        );
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.player,
      builder: (context, _) {
        final queue = widget.player.queue;
        // Content-stable, duplicate-safe keys: element state survives
        // reroll, removal and reorder.
        final keys = <String>[];
        final occurrences = <String, int>{};
        for (final item in queue) {
          final n = occurrences[item.id] ?? 0;
          occurrences[item.id] = n + 1;
          keys.add(n == 0 ? item.id : '${item.id}#${n + 1}');
        }
        final scheme = widget.scheme;
        if (queue.isEmpty) {
          return const Center(child: Text('Queue is empty'));
        }

        return Theme(
          data: Theme.of(context).copyWith(
            hoverColor: scheme.primary.withValues(alpha: 0.08),
            highlightColor: Colors.transparent,
            splashColor: scheme.primary.withValues(alpha: 0.12),
          ),
          child: ListView.builder(
            controller: _scrollController,
            // Fixed extent (dense two-line ListTile + 2px vertical padding):
            // O(1) scroll geometry.
            itemExtent: 68.0,
            itemCount: queue.length,
            findChildIndexCallback: (Key key) {
              final valueKey = key as ValueKey<String>?;
              if (valueKey == null) return null;
              final index = keys.indexWhere(
                (k) => 'wide_queue_$k' == valueKey.value,
              );
              return index >= 0 ? index : null;
            },
            itemBuilder: (context, i) {
              final item = queue[i];
              final isCurrent = item.id == widget.currentSong.id;
              final isUpcoming = i > widget.player.queueIndex;
              final isLocked = widget.player.isSongLocked(item.id);
              return RepaintBoundary(
                // Per-row repaint isolation: artwork decode and lock changes
                // do not repaint neighbouring rows.
                key: ValueKey('wide_queue_${keys[i]}'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Material(
                    color: isCurrent
                        ? scheme.primaryContainer.withValues(alpha: 0.35)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      dense: true,
                      mouseCursor: SystemMouseCursors.click,
                      hoverColor: scheme.primary.withValues(alpha: 0.08),
                      splashColor: scheme.primary.withValues(alpha: 0.12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      leading: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 24,
                            child: isCurrent
                                ? Icon(
                                    Icons.graphic_eq_rounded,
                                    color: scheme.primary,
                                    size: 18,
                                  )
                                : Text(
                                    '${i + 1}',
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant.withValues(
                                        alpha: 0.6,
                                      ),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                          const SizedBox(width: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: SizedBox(
                              width: 36,
                              height: 36,
                              child:
                                  item.artwork != null &&
                                      item.artwork!.startsWith('http')
                                  ? Image.network(
                                      item.artwork!,
                                      width: 36,
                                      height: 36,
                                      cacheWidth: 96,
                                      cacheHeight: 96,
                                      fit: BoxFit.cover,
                                      gaplessPlayback: true,
                                      errorBuilder: (_, _, _) => Container(
                                        color: scheme.surfaceContainerHighest,
                                        child: Icon(
                                          Icons.music_note,
                                          size: 18,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    )
                                  : FutureBuilder<Uint8List?>(
                                      initialData: ArtworkPalette.bytes(item),
                                      future: ArtworkPalette.bytesAsync(item),
                                      builder: (context, snapshot) {
                                        final bytes =
                                            snapshot.data ??
                                            ArtworkPalette.bytes(item);
                                        if (bytes != null && bytes.isNotEmpty) {
                                          return Image.memory(
                                            bytes,
                                            width: 36,
                                            height: 36,
                                            cacheWidth: 96,
                                            cacheHeight: 96,
                                            fit: BoxFit.cover,
                                            gaplessPlayback: true,
                                            errorBuilder: (_, _, _) =>
                                                Container(
                                                  color: scheme
                                                      .surfaceContainerHighest,
                                                  child: Icon(
                                                    Icons.music_note,
                                                    size: 18,
                                                    color:
                                                        scheme.onSurfaceVariant,
                                                  ),
                                                ),
                                          );
                                        }
                                        return Container(
                                          color: scheme.surfaceContainerHighest,
                                          child: Icon(
                                            Icons.music_note,
                                            size: 18,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ),
                        ],
                      ),
                      title: Text(
                        item.title,
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
                          Text(
                            item.sourceDeviceId == 'stream'
                                ? 'Radio Stream'
                                : (item.sourceDeviceId == null
                                      ? 'Local track'
                                      : 'Shared'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: isCurrent
                                      ? scheme.primary.withValues(alpha: 0.8)
                                      : scheme.onSurfaceVariant,
                                ),
                          ),
                          if (item.sourceDeviceId == 'stream' &&
                              StreamCacheManager.isStreamCachedSync(
                                RecommendationService.extractVideoId(item.id) ??
                                    item.id.replaceFirst('stream_', ''),
                              )) ...[
                            const SizedBox(width: 6),
                            const Tooltip(
                              message: 'Cached',
                              child: Icon(
                                Icons.check_circle_rounded,
                                size: 12,
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
                              iconSize: 18,
                              tooltip: 'Locked (tap to unlock)',
                              icon: Icon(
                                Icons.lock_rounded,
                                color: scheme.primary,
                              ),
                              onPressed: () =>
                                  widget.player.toggleSongLock(item.id),
                            ),
                          if (isCurrent)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                'PLAYING',
                                style: TextStyle(
                                  color: scheme.onPrimary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
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
                                widget.player.toggleSongLock(item.id);
                              } else if (action == 'save') {
                                context
                                    .read<AppController>()
                                    .saveStreamToLibrary(item);
                              } else if (action == 'remove') {
                                context.read<AppController>().removeFromQueue(
                                  i,
                                );
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
                                      Text(
                                        isLocked
                                            ? 'Unlock track'
                                            : 'Lock track',
                                      ),
                                    ],
                                  ),
                                ),
                              if (item.sourceDeviceId == 'stream')
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
                      onTap: () => widget.player.playSong(item, queue: queue),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class PlayerWidePlaylistsView extends StatelessWidget {
  final AppController controller;
  final String? activePlaylistId;
  final ValueChanged<Playlist> onSelect;
  final ColorScheme scheme;
  const PlayerWidePlaylistsView({
    super.key,
    required this.controller,
    required this.activePlaylistId,
    required this.onSelect,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final playlists = controller.playlists;
    if (playlists.isEmpty) {
      return const Center(child: Text('No playlists yet'));
    }

    return Theme(
      data: Theme.of(context).copyWith(
        hoverColor: scheme.primary.withValues(alpha: 0.08),
        highlightColor: Colors.transparent,
        splashColor: scheme.primary.withValues(alpha: 0.12),
      ),
      child: ListView.builder(
        itemCount: playlists.length,
        itemBuilder: (context, i) {
          final pl = playlists[i];
          final selected = pl.id == activePlaylistId;
          return RepaintBoundary(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Material(
                color: selected
                    ? scheme.primaryContainer.withValues(alpha: 0.35)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  dense: true,
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: scheme.primary.withValues(alpha: 0.08),
                  splashColor: scheme.primary.withValues(alpha: 0.12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  leading: Icon(
                    Icons.playlist_play_rounded,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  title: Text(
                    pl.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: selected
                        ? TextStyle(
                            color: scheme.primary,
                            fontWeight: FontWeight.bold,
                          )
                        : null,
                  ),
                  subtitle: Text('${pl.songIds.length} songs'),
                  trailing: IconButton(
                    icon: const Icon(Icons.play_circle_filled_rounded),
                    color: scheme.primary,
                    tooltip: 'Play playlist',
                    onPressed: () => onSelect(pl),
                  ),
                  onTap: () => onSelect(pl),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
