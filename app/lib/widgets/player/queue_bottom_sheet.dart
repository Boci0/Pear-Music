import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/artwork_service.dart';
import '../../services/player_service.dart';

/// YouTube Music style pull-up queue bottom sheet.
class QueueBottomSheet extends StatefulWidget {
  final PlayerService player;
  final AppController controller;
  final Color accent;

  const QueueBottomSheet({
    super.key,
    required this.player,
    required this.controller,
    required this.accent,
  });

  static Future<void> show(
    BuildContext context, {
    required PlayerService player,
    required AppController controller,
    required Color accent,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QueueBottomSheet(
        player: player,
        controller: controller,
        accent: accent,
      ),
    );
  }

  @override
  State<QueueBottomSheet> createState() => _QueueBottomSheetState();
}

class _QueueBottomSheetState extends State<QueueBottomSheet> {
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  bool _didScrollToCurrent = false;

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  void _maybeScrollToCurrent(ScrollController controller) {
    if (_didScrollToCurrent || !mounted) return;
    final index = widget.player.queueIndex;
    if (index > 2 && controller.hasClients) {
      _didScrollToCurrent = true;
      final offset = (index - 1) * 60.0;
      controller.animateTo(
        offset.clamp(0.0, controller.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.player,
      builder: (context, _) {
        final player = widget.player;
        final queue = player.queue;
        final accent = widget.accent;

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
        controller: _sheetController,
        initialChildSize: 0.75,
        minChildSize: 0.40,
        maxChildSize: 0.94,
        builder: (context, sheetScrollController) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _maybeScrollToCurrent(sheetScrollController),
          );
          return Container(
            decoration: BoxDecoration(
              color: const Color(0xFF141418),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(
                top: BorderSide(
                  color: Colors.white.withValues(alpha: 0.10),
                  width: 1,
                ),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black54,
                  blurRadius: 24,
                  offset: Offset(0, -6),
                ),
              ],
            ),
            child: Column(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (details) {
                    final delta = details.primaryDelta ?? 0.0;
                    final totalHeight = MediaQuery.sizeOf(context).height;
                    if (totalHeight > 0 && _sheetController.isAttached) {
                      final newSize = (_sheetController.size -
                              (delta / totalHeight))
                          .clamp(0.0, 0.94);
                      if (newSize < 0.32) {
                        Navigator.of(context).pop();
                      } else {
                        _sheetController.jumpTo(newSize);
                      }
                    }
                  },
                  onVerticalDragEnd: (details) {
                    final vy = details.primaryVelocity ?? 0.0;
                    if (vy > 250 ||
                        (_sheetController.isAttached &&
                            _sheetController.size < 0.45)) {
                      Navigator.of(context).pop();
                    } else if (vy < -250 && _sheetController.isAttached) {
                      _sheetController.animateTo(
                        0.94,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                      );
                    }
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Drag Handle
                      Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(top: 10, bottom: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.28),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),

                      // Header: "Up Next (count)", Autoplay Chip, Close
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 4, 12, 10),
                        child: Row(
                          children: [
                            Icon(Icons.queue_music_rounded,
                                size: 20, color: accent),
                            const SizedBox(width: 8),
                            Text(
                              'Up Next',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: -0.2,
                                  ),
                            ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${queue.length}',
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
                      onTap: () {
                        setState(() {
                          player.setAutoplay(!player.autoplay);
                        });
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
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
                              size: 14,
                              color: player.autoplay
                                  ? accent
                                  : Colors.white.withValues(alpha: 0.5),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'Autoplay',
                              style: TextStyle(
                                fontSize: 11.5,
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
                      iconSize: 20,
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Reroll upcoming recommendations',
                      icon: Icon(Icons.casino_outlined, color: accent),
                      onPressed: () {
                        player.rerollUpcomingQueue();
                        setState(() {});
                      },
                    ),

                    // Close button
                    IconButton(
                      iconSize: 20,
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Close',
                      icon: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 24,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

              const Divider(height: 1, color: Color(0x1AFFFFFF)),

              // Track list
              Expanded(
                child: queue.isEmpty
                    ? const Center(
                        child: Text(
                          'Queue is empty',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : ListView.builder(
                        controller: sheetScrollController,
                        itemCount: queue.length,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        itemBuilder: (context, i) {
                          final song = queue[i];
                          final isCurrent = i == player.queueIndex;
                          return _QueueRow(
                            key: ValueKey('queue_sheet_${song.id}_$i'),
                            song: song,
                            index: i,
                            isCurrent: isCurrent,
                            accent: accent,
                            onTap: () {
                              player.playSong(
                                song,
                                queue: queue,
                                sourceId: player.queueSourceId,
                              );
                              Navigator.of(context).pop();
                            },
                            onRemove: () {
                              player.removeFromQueue(i);
                              setState(() {});
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
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
    final isNetwork = song.artwork != null && song.artwork!.startsWith('http');

    final Widget artworkWidget = isNetwork
        ? ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.network(
              ArtworkService.optimizeArtworkUrl(song.artwork!),
              width: 38,
              height: 38,
              cacheWidth: 96,
              cacheHeight: 96,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _placeholder(),
            ),
          )
        : FutureBuilder<Uint8List?>(
            initialData: ArtworkPalette.bytes(song),
            future: ArtworkPalette.bytesAsync(song),
            builder: (context, snapshot) {
              final bytes = snapshot.data ?? ArtworkPalette.bytes(song);
              if (bytes == null || bytes.isEmpty) return _placeholder();
              return ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  bytes,
                  width: 38,
                  height: 38,
                  cacheWidth: 96,
                  cacheHeight: 96,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _placeholder(),
                ),
              );
            },
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: isCurrent
                  ? LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        accent.withValues(alpha: 0.16),
                        accent.withValues(alpha: 0.02),
                      ],
                    )
                  : null,
              border: isCurrent
                  ? Border.all(
                      color: accent.withValues(alpha: 0.20),
                      width: 1,
                    )
                  : null,
            ),
            child: SizedBox(
              height: 56,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  if (isCurrent)
                    Positioned(
                      left: 3,
                      child: Container(
                        width: 3.5,
                        height: 20,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(2),
                          boxShadow: [
                            BoxShadow(
                              color: accent.withValues(alpha: 0.65),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(left: 12, right: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 24,
                          child: isCurrent
                              ? Icon(
                                  Icons.graphic_eq_rounded,
                                  color: accent,
                                  size: 18,
                                )
                              : Text(
                                  '${index + 1}',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white.withValues(alpha: 0.45),
                                  ),
                                ),
                        ),
                        const SizedBox(width: 8),
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
                                  fontSize: 14,
                                  fontWeight: isCurrent
                                      ? FontWeight.w600
                                      : FontWeight.w500,
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
                                  fontSize: 11.5,
                                  color: Colors.white.withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (!isCurrent)
                          IconButton(
                            iconSize: 18,
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Remove from queue',
                            icon: Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: Colors.white.withValues(alpha: 0.4),
                            ),
                            onPressed: onRemove,
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
    );
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
        isCurrent ? Icons.music_note : Icons.audiotrack,
        size: 18,
        color: isCurrent ? accent : Colors.white54,
      ),
    );
  }
}
