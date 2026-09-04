import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/artwork_service.dart';
import '../services/youtube_search_service.dart';

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

  Future<void> _streamAndPlay(BuildContext context, AppController controller) async {
    final song = widget.result.toSong();
    final queue = widget.allResults?.map((r) => r.toSong()).toList();
    await controller.player.playSong(
      song,
      queue: queue,
      sourceId: 'search:streaming',
      sourceTitle: 'Online Stream',
    );
  }

  void _showOptions(BuildContext context, AppController controller) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: widget.result.thumbnailUrl != null
                    ? Image.network(
                        ArtworkService.optimizeArtworkUrl(widget.result.thumbnailUrl!),
                        width: 48,
                        height: 48,
                        cacheWidth: 100,
                        cacheHeight: 100,
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        errorBuilder: (_, _, _) => Image.network(
                          widget.result.thumbnailUrl!,
                          width: 48,
                          height: 48,
                          cacheWidth: 100,
                          cacheHeight: 100,
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
                style: const TextStyle(fontWeight: FontWeight.bold),
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
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy title'),
              onTap: () async {
                Navigator.of(ctx).pop();
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
              },
            ),
          ],
        ),
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
        SnackBar(
          content: Text(res.error!),
          backgroundColor: Colors.redAccent,
        ),
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
              cacheHeight: 88,
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

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1.5),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _streamAndPlay(context, controller),
            onLongPress: () => _showOptions(context, controller),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: widget.isCurrent
                    ? LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          theme.colorScheme.primary.withValues(alpha: 0.16),
                          theme.colorScheme.primary.withValues(alpha: 0.02),
                        ],
                      )
                    : null,
                border: widget.isCurrent
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
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _artwork(theme),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.result.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontSize: 14.5,
                                    fontWeight: widget.isCurrent ? FontWeight.w600 : FontWeight.w500,
                                    color: widget.isCurrent ? theme.colorScheme.primary : null,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    Icon(Icons.sensors_rounded,
                                        size: 13, color: theme.colorScheme.tertiary),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        'Online · ${widget.result.author}${widget.result.duration != null ? ' · ${widget.result.durationFormatted}' : ''}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          fontSize: 12,
                                          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (_isDownloading) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
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
                          ] else if (widget.isCurrent) ...[
                            Icon(
                              Icons.graphic_eq_rounded,
                              size: 18,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                          ],
                          IconButton(
                            icon: const Icon(Icons.more_vert, size: 20),
                            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
                            tooltip: 'Song options',
                            onPressed: () => _showOptions(context, controller),
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
}
