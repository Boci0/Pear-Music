import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/artwork_service.dart';
import '../services/youtube_search_service.dart';
import '../theme/tokens.dart';
import 'pear_popup.dart';
import 'tactile_button.dart';
import '../theme/glass.dart';

/// A list tile representing a YouTube search result with instant streaming playback
/// and optional background download to library.
class YouTubeSongTile extends StatefulWidget {
  final YouTubeSearchResult result;
  final List<YouTubeSearchResult>? allResults;
  final bool isCurrent;

  const YouTubeSongTile({
    super.key,
    required this.result,
    this.allResults,
    this.isCurrent = false,
  });

  @override
  State<YouTubeSongTile> createState() => _YouTubeSongTileState();
}

class _YouTubeSongTileState extends State<YouTubeSongTile> {
  bool _isDownloading = false;
  double? _downloadProgress;

  Future<void> _streamAndPlay(
    BuildContext context,
    AppController controller,
  ) async {
    final song = widget.result.toSong();
    final queue = widget.allResults?.map((r) => r.toSong()).toList();
    await controller.player.playSong(
      song,
      queue: queue,
      sourceId: 'search:streaming',
      sourceTitle: 'Online Stream',
    );
  }

  void _showOptions(
    BuildContext context,
    AppController controller, {
    Offset? anchor,
  }) {
    final theme = Theme.of(context);
    showPearPopup<void>(
      context: context,
      showDragHandle: true,
      maxWidth: 380,
      anchor: anchor,
      anchorAlignRight: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: ClipRRect(
                // Thumbnails in rows share the row-thumbnail radius, even at
                // this menu's 48px size.
                borderRadius: PearRadius.thumbAll,
                child: widget.result.thumbnailUrl != null
                    ? Image.network(
                        ArtworkService.optimizeArtworkUrl(
                          widget.result.thumbnailUrl!,
                        ),
                        width: 48,
                        height: 48,
                        cacheWidth: 100,
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        errorBuilder: (_, _, _) => Image.network(
                          widget.result.thumbnailUrl!,
                          width: 48,
                          height: 48,
                          cacheWidth: 100,
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          errorBuilder: (_, _, _) => Container(
                            width: 48,
                            height: 48,
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.music_note),
                          ),
                        ),
                      )
                    : Container(
                        width: 48,
                        height: 48,
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.music_note),
                      ),
              ),
              title: Text(
                widget.result.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                widget.result.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: const Text('Stream Now'),
              subtitle: const Text('Instant streaming playback'),
              onTap: () {
                Navigator.of(ctx).pop();
                _streamAndPlay(context, controller);
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_play_rounded),
              title: const Text('Play next'),
              onTap: () {
                Navigator.of(ctx).pop();
                final song = widget.result.toSong();
                controller.playNext(song);
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: const Text('Add to queue'),
              onTap: () {
                Navigator.of(ctx).pop();
                final song = widget.result.toSong();
                controller.addToQueue(song);
              },
            ),
            ListTile(
              leading: _isDownloading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              title: const Text('Download to Library'),
              subtitle: const Text(
                'Save for offline listening without interrupting playback',
              ),
              onTap: _isDownloading
                  ? null
                  : () {
                      Navigator.of(ctx).pop();
                      _downloadToLibrary(context, controller);
                    },
            ),
            Builder(
              builder: (ctx) {
                final song = widget.result.toSong();
                final isFav = controller.isFavorite(song.id);
                return ListTile(
                  leading: Icon(
                    isFav ? Icons.favorite : Icons.favorite_border,
                    color: isFav ? theme.colorScheme.primary : null,
                  ),
                  title: Text(
                    isFav ? 'Remove from favorites' : 'Add to favorites',
                  ),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    await controller.toggleFavorite(song.id, song: song);
                  },
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy title'),
              onTap: () async {
                Navigator.of(ctx).pop();
                await Clipboard.setData(
                  ClipboardData(text: widget.result.title),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Copied "${widget.result.title}" to clipboard',
                      ),
                      duration: const Duration(seconds: 2),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Right-click context menu mirroring the long-press sheet options.
  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final controller = context.read<AppController>();
    final isFav = controller.isFavorite('stream_${widget.result.videoId}');
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        _menuItem('stream', Icons.play_circle_outline, 'Stream Now'),
        _menuItem('play_next', Icons.playlist_play_rounded, 'Play next'),
        _menuItem('add_to_queue', Icons.queue_music_rounded, 'Add to queue'),
        if (!_isDownloading)
          _menuItem('download', Icons.download, 'Download to Library'),
        _menuItem(
          'favorite',
          isFav ? Icons.favorite : Icons.favorite_border,
          isFav ? 'Remove from favorites' : 'Add to favorites',
          color: isFav ? Theme.of(context).colorScheme.primary : null,
        ),
        _menuItem('copy_title', Icons.copy_rounded, 'Copy title'),
      ],
    );
    if (!context.mounted || selected == null) return;
    final song = widget.result.toSong();
    switch (selected) {
      case 'stream':
        _streamAndPlay(context, controller);
      case 'play_next':
        controller.playNext(song);
      case 'add_to_queue':
        controller.addToQueue(song);
      case 'download':
        _downloadToLibrary(context, controller);
      case 'favorite':
        await controller.toggleFavorite(
          'stream_${widget.result.videoId}',
          song: song,
        );
      case 'copy_title':
        await Clipboard.setData(ClipboardData(text: widget.result.title));
        if (context.mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Copied "${widget.result.title}" to clipboard'),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
    }
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    Color? color,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: 42,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              label,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadToLibrary(
    BuildContext context,
    AppController controller,
  ) async {
    if (_isDownloading) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _isDownloading = true;
      _downloadProgress = null;
    });

    messenger.showSnackBar(
      SnackBar(
        content: Text('Downloading "${widget.result.title}" to library...'),
        duration: const Duration(seconds: 3),
      ),
    );

    final res = await controller.downloadAndGetYouTubeSong(
      widget.result,
      onProgress: (downloaded, total) {
        if (mounted) {
          setState(() {
            _downloadProgress = total > 0 ? (downloaded / total) : null;
          });
        }
      },
    );

    if (!mounted) return;

    setState(() {
      _isDownloading = false;
      _downloadProgress = null;
    });

    if (res.error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(res.error!), backgroundColor: Colors.redAccent),
      );
    } else if (res.song != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Downloaded "${res.song!.title}" to library.'),
          backgroundColor: Colors.teal,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _artwork(ThemeData theme) {
    final thumb = widget.result.thumbnailUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: thumb != null && thumb.isNotEmpty
          ? Image.network(
              ArtworkService.optimizeArtworkUrl(thumb),
              key: ValueKey('yt_thumb_${widget.result.videoId}'),
              width: 44,
              height: 44,
              cacheWidth: 88,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _placeholder(theme),
            )
          : _placeholder(theme),
    );
  }

  Widget _placeholder(ThemeData theme) {
    return Container(
      width: 44,
      height: 44,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, color: theme.colorScheme.primary, size: 20),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = context.read<AppController>();
    final isFav = context.select<AppController, bool>(
      (c) => c.isFavorite('stream_${widget.result.videoId}'),
    );

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Material(
          color: Colors.transparent,
          child: GestureDetector(
            onSecondaryTapDown: (details) =>
                _showContextMenu(context, details.globalPosition),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                TactileFeedback.click();
                _streamAndPlay(context, controller);
              },
              onLongPress: () => _showOptions(
                context,
                controller,
                anchor: popupAnchorBelowRight(context, insetX: 10, insetY: 6),
              ),
              hoverColor: Colors.white.withValues(alpha: 0.055),
              // Desktop rows: an instant press fill instead of the touch
              // ripple, which animates exactly while the song change re-seeds
              // the theme and read as laggy.
              splashFactory: NoSplash.splashFactory,
              highlightColor: Colors.white.withValues(alpha: 0.06),
              child: Ink(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: widget.isCurrent
                      ? LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            theme.colorScheme.primary.withValues(alpha: 0.18),
                            theme.colorScheme.primary.withValues(alpha: 0.02),
                          ],
                        )
                      : null,
                  // Same card body as the playlist tile: a visible fill when
                  // idle, the accent gradient when this row is playing.
                  color: widget.isCurrent
                      ? null
                      : Colors.white.withValues(
                          alpha: PearGlassTokens.cardFill,
                        ),
                ),
                child: SizedBox(
                  height: 64,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      if (widget.isCurrent)
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
                        padding: const EdgeInsets.only(left: 14, right: 8),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            // Wide rows (desktop) move the meta line into a
                            // right-aligned column so the row reads like a table.
                            final wideRow = constraints.maxWidth >= 620;
                            final onlineMeta =
                                'Online · ${widget.result.author}${widget.result.duration != null ? ' · ${widget.result.durationFormatted}' : ''}';
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                _artwork(theme),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.result.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontSize: 15,
                                              height: 1.25,
                                              fontWeight: FontWeight.w600,
                                              color: widget.isCurrent
                                                  ? theme.colorScheme.primary
                                                  : null,
                                              letterSpacing: -0.2,
                                            ),
                                      ),
                                      const SizedBox(height: 3),
                                      if (!wideRow)
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.sensors_rounded,
                                              size: 13,
                                              color: theme.colorScheme.tertiary,
                                            ),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                onlineMeta,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      fontSize: 12.5,
                                                      height: 1.25,
                                                      color: theme
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (wideRow) ...[
                                  SizedBox(
                                    width: 168,
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        Icon(
                                          Icons.sensors_rounded,
                                          size: 13,
                                          color: theme.colorScheme.tertiary,
                                        ),
                                        const SizedBox(width: 4),
                                        Flexible(
                                          child: Text(
                                            onlineMeta,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  fontSize: 12.5,
                                                  color: theme
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  SizedBox(
                                    width: 44,
                                    child: isFav
                                        ? TactileIconButton(
                                            icon: const Icon(
                                              Icons.favorite,
                                              size: 19,
                                            ),
                                            color: theme.colorScheme.primary,
                                            tooltip: 'Favorite',
                                            onPressed: () =>
                                                controller.toggleFavorite(
                                                  'stream_${widget.result.videoId}',
                                                  song: widget.result.toSong(),
                                                ),
                                          )
                                        : null,
                                  ),
                                  SizedBox(
                                    width: 22,
                                    child: widget.isCurrent
                                        ? Icon(
                                            Icons.graphic_eq_rounded,
                                            size: 18,
                                            color: theme.colorScheme.primary,
                                          )
                                        : null,
                                  ),
                                ],
                                if (_isDownloading) ...[
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    child: SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        value: _downloadProgress,
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                if (!wideRow && isFav) ...[
                                  TactileIconButton(
                                    icon: const Icon(Icons.favorite, size: 19),
                                    color: theme.colorScheme.primary,
                                    tooltip: 'Favorite',
                                    onPressed: () => controller.toggleFavorite(
                                      'stream_${widget.result.videoId}',
                                      song: widget.result.toSong(),
                                    ),
                                  ),
                                ],
                                if (!wideRow && widget.isCurrent) ...[
                                  Icon(
                                    Icons.graphic_eq_rounded,
                                    size: 18,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                Builder(
                                  builder: (menuContext) => TactileIconButton(
                                    icon: const Icon(Icons.more_vert, size: 20),
                                    color: theme.colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.75),
                                    tooltip: 'Song options',
                                    onPressed: () => _showOptions(
                                      context,
                                      controller,
                                      anchor: popupAnchorBelowRight(menuContext),
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
}
