import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/artwork_service.dart';
import '../../services/player_service.dart';

/// YouTube Music style pull-up queue bottom sheet with 1:1 drag gesture tracking,
/// 60/120fps fixed-extent virtualization, and layer-isolated repainting.
class ExpandableQueueSheet extends StatefulWidget {
  final PlayerService player;
  final AppController controller;
  final Color accent;
  final double minChildSize;
  final DraggableScrollableController sheetController;

  const ExpandableQueueSheet({
    super.key,
    required this.player,
    required this.controller,
    required this.accent,
    required this.minChildSize,
    required this.sheetController,
  });

  @override
  State<ExpandableQueueSheet> createState() => _ExpandableQueueSheetState();
}

class _ExpandableQueueSheetState extends State<ExpandableQueueSheet> {
  static const double _expandedSize = 0.92;

  ScrollController? _scrollController;
  bool _didScrollToCurrent = false;
  bool _isCollapsing = false;
  double _lastSize = 0.0;
  DateTime _lastToggleTime = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    widget.sheetController.addListener(_onSheetSizeChanged);
  }

  @override
  void dispose() {
    widget.sheetController.removeListener(_onSheetSizeChanged);
    super.dispose();
  }

  void _onSheetSizeChanged() {
    if (!widget.sheetController.isAttached) return;
    final currentSize = widget.sheetController.size;
    final isExpanding = currentSize > _lastSize;
    _lastSize = currentSize;

    if (currentSize <= widget.minChildSize + 0.03) {
      _didScrollToCurrent = false;
    } else if (isExpanding && !_isCollapsing && currentSize >= 0.70 && !_didScrollToCurrent) {
      _maybeScrollToCurrent();
    }
  }

  void _maybeScrollToCurrent() {
    if (_isCollapsing || _didScrollToCurrent || !mounted) return;
    final controller = _scrollController;
    if (controller == null || !controller.hasClients) return;

    final index = widget.player.queueIndex;
    if (index > 2) {
      _didScrollToCurrent = true;
      final targetOffset = (index - 1) * 58.0;
      controller.animateTo(
        targetOffset.clamp(0.0, controller.position.maxScrollExtent),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _toggleSheet() {
    final now = DateTime.now();
    if (now.difference(_lastToggleTime).inMilliseconds < 280) {
      return;
    }
    _lastToggleTime = now;

    if (!widget.sheetController.isAttached) return;
    final currentSize = widget.sheetController.size;
    final isExpanded = currentSize > (widget.minChildSize + 0.05);
    if (isExpanded) {
      _collapseSheet();
    } else {
      _expandSheet();
    }
  }

  void _collapseSheet() {
    if (!widget.sheetController.isAttached) return;
    _isCollapsing = true;
    _didScrollToCurrent = true;
    if (_scrollController != null && _scrollController!.hasClients) {
      _scrollController!.jumpTo(0.0);
    }
    widget.sheetController.animateTo(
      widget.minChildSize,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    ).then((_) {
      if (mounted) {
        _isCollapsing = false;
        _didScrollToCurrent = false;
      }
    });
  }

  void _expandSheet() {
    if (!widget.sheetController.isAttached) return;
    _isCollapsing = false;
    _didScrollToCurrent = false;
    widget.sheetController.animateTo(
      _expandedSize,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    ).then((_) {
      _maybeScrollToCurrent();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      child: DraggableScrollableSheet(
        controller: widget.sheetController,
        initialChildSize: widget.minChildSize,
        minChildSize: widget.minChildSize,
        maxChildSize: _expandedSize,
        snap: true,
        snapSizes: const [],
        builder: (context, scrollController) {
          _scrollController = scrollController;

          return Container(
            decoration: BoxDecoration(
              color: const Color(0xFF141418),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(22)),
              border: Border(
                top: BorderSide(
                  color: Colors.white.withValues(alpha: 0.12),
                  width: 1,
                ),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black54,
                  blurRadius: 18,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: CustomScrollView(
              controller: scrollController,
              physics: const ClampingScrollPhysics(),
              slivers: [
                // Pinned Header: adapts between peek and full toolbar
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _QueueHeaderDelegate(
                    player: widget.player,
                    accent: widget.accent,
                    minChildSize: widget.minChildSize,
                    expandedSize: _expandedSize,
                    sheetController: widget.sheetController,
                    onToggle: _toggleSheet,
                    onCollapse: _collapseSheet,
                    onExpand: _expandSheet,
                  ),
                ),

                const SliverToBoxAdapter(
                  child: Divider(height: 1, color: Color(0x1AFFFFFF)),
                ),

                // Real-time reactively updated track list
                _QueueListSliver(
                  player: widget.player,
                  accent: widget.accent,
                  onSelectSong: (song, queue) {
                    widget.player.playSong(
                      song,
                      queue: queue,
                      sourceId: widget.player.queueSourceId,
                    );
                    _collapseSheet();
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _QueueHeaderDelegate extends SliverPersistentHeaderDelegate {
  final PlayerService player;
  final Color accent;
  final double minChildSize;
  final double expandedSize;
  final DraggableScrollableController sheetController;
  final VoidCallback onToggle;
  final VoidCallback onCollapse;
  final VoidCallback onExpand;

  const _QueueHeaderDelegate({
    required this.player,
    required this.accent,
    required this.minChildSize,
    required this.expandedSize,
    required this.sheetController,
    required this.onToggle,
    required this.onCollapse,
    required this.onExpand,
  });

  @override
  double get minExtent => 62.0;

  @override
  double get maxExtent => 62.0;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      height: 62.0,
      color: const Color(0xFF141418),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) {
          final delta = details.primaryDelta ?? 0.0;
          final totalHeight = MediaQuery.sizeOf(context).height;
          if (totalHeight > 0 && sheetController.isAttached) {
            final nextSize =
                (sheetController.size - (delta / totalHeight)).clamp(minChildSize, expandedSize);
            sheetController.jumpTo(nextSize);
          }
        },
        onVerticalDragEnd: (details) {
          final vy = details.primaryVelocity ?? 0.0;
          if (!sheetController.isAttached) return;
          final midPoint = (minChildSize + expandedSize) / 2;
          if (vy > 250 || sheetController.size < midPoint) {
            onCollapse();
          } else {
            onExpand();
          }
        },
        onTap: () {
          if (!sheetController.isAttached) return;
          if (sheetController.size <= minChildSize + 0.05) {
            onToggle();
          }
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Centered drag handle bar acting as the unified expand/collapse toggle
            Center(
              child: Tooltip(
                message: 'Toggle queue',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onToggle,
                    child: Container(
                      padding: const EdgeInsets.only(
                        top: 8,
                        bottom: 6,
                        left: 36,
                        right: 36,
                      ),
                      color: Colors.transparent,
                      child: Container(
                        width: 38,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.32),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Header row switching smoothly between collapsed peek and full toolbar
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: ListenableBuilder(
                  listenable: sheetController,
                  builder: (context, _) {
                    final currentSize = sheetController.isAttached
                        ? sheetController.size
                        : minChildSize;
                    final isExpanded = currentSize > (minChildSize + 0.05);

                    return ListenableBuilder(
                      listenable: player,
                      builder: (context, _) {
                        final queue = player.queue;
                        final nextIndex = player.queueIndex + 1;
                        final nextSong = (nextIndex < queue.length)
                            ? queue[nextIndex]
                            : null;

                        if (isExpanded) {
                          return _buildExpandedToolbar(context, queue.length);
                        } else {
                          return _buildCollapsedPeek(context, queue.length, nextSong);
                        }
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollapsedPeek(
      BuildContext context, int queueLength, Song? nextSong) {
    return Row(
      children: [
        Icon(Icons.queue_music_rounded, size: 18, color: accent),
        const SizedBox(width: 8),
        Text(
          'UP NEXT',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
            color: accent,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '$queueLength',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: accent,
            ),
          ),
        ),
        if (nextSong != null) ...[
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              nextSong.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.65),
              ),
            ),
          ),
        ] else ...[
          const Spacer(),
        ],
      ],
    );
  }

  Widget _buildExpandedToolbar(BuildContext context, int queueLength) {
    return Row(
      children: [
        Icon(Icons.queue_music_rounded, size: 20, color: accent),
        const SizedBox(width: 8),
        Text(
          'Up Next',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: -0.2,
              ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '$queueLength',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: accent,
            ),
          ),
        ),
        const Spacer(),

        // Autoplay toggle chip
        InkWell(
          onTap: () => player.setAutoplay(!player.autoplay),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: player.autoplay
                  ? accent.withValues(alpha: 0.18)
                  : Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: player.autoplay
                    ? accent.withValues(alpha: 0.4)
                    : Colors.white.withValues(alpha: 0.08),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 13,
                  color: player.autoplay
                      ? accent
                      : Colors.white.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 4),
                Text(
                  'Autoplay',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: player.autoplay
                        ? accent
                        : Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(width: 4),

        // Reroll recommendations button
        IconButton(
          iconSize: 19,
          visualDensity: VisualDensity.compact,
          tooltip: 'Reroll upcoming recommendations',
          icon: Icon(Icons.casino_outlined, color: accent),
          onPressed: () => player.rerollUpcomingQueue(),
        ),
      ],
    );
  }

  @override
  bool shouldRebuild(covariant _QueueHeaderDelegate oldDelegate) {
    return oldDelegate.accent != accent ||
        oldDelegate.minChildSize != minChildSize ||
        oldDelegate.expandedSize != expandedSize ||
        oldDelegate.sheetController != sheetController ||
        oldDelegate.onToggle != onToggle ||
        oldDelegate.onCollapse != onCollapse ||
        oldDelegate.onExpand != onExpand;
  }
}

class _QueueListSliver extends StatelessWidget {
  final PlayerService player;
  final Color accent;
  final void Function(Song song, List<Song> queue) onSelectSong;

  const _QueueListSliver({
    required this.player,
    required this.accent,
    required this.onSelectSong,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final queue = player.queue;
        final currentIndex = player.queueIndex;

        if (queue.isEmpty) {
          return const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                'Queue is empty',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          );
        }

        return SliverFixedExtentList(
          itemExtent: 58.0,
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final song = queue[i];
              final isCurrent = i == currentIndex;

              return _QueueRow(
                key: ValueKey('queue_row_${song.id}'),
                song: song,
                index: i,
                isCurrent: isCurrent,
                accent: accent,
                onTap: () => onSelectSong(song, queue),
                onRemove: () => player.removeFromQueue(i),
              );
            },
            childCount: queue.length,
          ),
        );
      },
    );
  }
}

class _QueueRow extends StatelessWidget {
  final Song song;
  final int index;
  final bool isCurrent;
  final Color accent;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _QueueRow({
    super.key,
    required this.song,
    required this.index,
    required this.isCurrent,
    required this.accent,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 55,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: isCurrent
                  ? accent.withValues(alpha: 0.12)
                  : Colors.transparent,
              border: isCurrent
                  ? Border.all(
                      color: accent.withValues(alpha: 0.22),
                      width: 1,
                    )
                  : null,
            ),
            child: Row(
              children: [
                // Active bar indicator or index
                SizedBox(
                  width: 32,
                  child: Center(
                    child: isCurrent
                        ? Container(
                            width: 3,
                            height: 18,
                            decoration: BoxDecoration(
                              color: accent,
                              borderRadius: BorderRadius.circular(1.5),
                            ),
                          )
                        : Text(
                            '${index + 1}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.40),
                            ),
                          ),
                  ),
                ),

                // Artwork Thumbnail
                _QueueArtworkThumbnail(
                  song: song,
                  isCurrent: isCurrent,
                  accent: accent,
                ),

                const SizedBox(width: 12),

                // Song Title & Details
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
                          fontSize: 13.5,
                          fontWeight:
                              isCurrent ? FontWeight.w600 : FontWeight.w500,
                          color: isCurrent
                              ? accent
                              : Colors.white.withValues(alpha: 0.9),
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.sizeLabel,
                        maxLines: 1,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),

                // Remove button for non-playing tracks
                if (!isCurrent)
                  IconButton(
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Remove from queue',
                    icon: Icon(
                      Icons.close_rounded,
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                    onPressed: onRemove,
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Icon(
                      Icons.graphic_eq_rounded,
                      color: accent,
                      size: 18,
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

class _QueueArtworkThumbnail extends StatefulWidget {
  final Song song;
  final bool isCurrent;
  final Color accent;

  const _QueueArtworkThumbnail({
    required this.song,
    required this.isCurrent,
    required this.accent,
  });

  @override
  State<_QueueArtworkThumbnail> createState() => _QueueArtworkThumbnailState();
}

class _QueueArtworkThumbnailState extends State<_QueueArtworkThumbnail> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _loadArtwork();
  }

  @override
  void didUpdateWidget(covariant _QueueArtworkThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id) {
      _loadArtwork();
    }
  }

  void _loadArtwork() {
    final art = widget.song.artwork;
    if (art == null || art.isEmpty) {
      _bytes = null;
      return;
    }
    if (art.startsWith('http')) {
      _bytes = null;
      return;
    }
    final cached = ArtworkPalette.bytes(widget.song);
    if (cached != null) {
      _bytes = cached;
      return;
    }
    // Asynchronous background isolate load without blocking UI thread
    ArtworkPalette.bytesAsync(widget.song).then((decoded) {
      if (mounted && decoded != null) {
        setState(() => _bytes = decoded);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final art = widget.song.artwork;
    final isNetwork = art != null && art.startsWith('http');

    if (_bytes != null && _bytes!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(
          _bytes!,
          width: 38,
          height: 38,
          cacheWidth: 96,
          cacheHeight: 96,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _placeholder(),
        ),
      );
    }

    if (isNetwork) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(
          ArtworkService.optimizeArtworkUrl(art),
          width: 38,
          height: 38,
          cacheWidth: 96,
          cacheHeight: 96,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _placeholder(),
        ),
      );
    }

    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        widget.isCurrent ? Icons.music_note : Icons.audiotrack,
        size: 18,
        color: widget.isCurrent ? widget.accent : Colors.white54,
      ),
    );
  }
}
