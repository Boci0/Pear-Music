import 'package:flutter/material.dart';
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = context.read<AppController>();

    return RepaintBoundary(
      child: ListTile(
        tileColor: widget.isCurrent
            ? (theme.brightness == Brightness.dark
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.28)
                  : theme.colorScheme.primaryContainer.withValues(alpha: 0.40))
            : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Stack(
          alignment: Alignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: widget.result.thumbnailUrl != null
                  ? Image.network(
                      widget.result.thumbnailUrl!,
                      width: 48,
                      height: 48,
                      cacheWidth: 96,
                      cacheHeight: 96,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 48,
                        height: 48,
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.music_note),
                      ),
                    )
                  : Container(
                      width: 48,
                      height: 48,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.music_note),
                    ),
            ),
            if (widget.isCurrent)
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: Colors.black.withValues(alpha: 0.4),
                ),
                child: const Icon(
                  Icons.equalizer,
                  color: Colors.white,
                  size: 24,
                ),
              ),
          ],
        ),
        title: Text(
          widget.result.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: widget.isCurrent ? FontWeight.bold : FontWeight.w500,
            color: widget.isCurrent ? theme.colorScheme.primary : null,
          ),
        ),
        subtitle: Row(
          children: [
            Icon(Icons.sensors_rounded,
                size: 13, color: theme.colorScheme.tertiary),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                widget.result.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (widget.result.durationFormatted != null) ...[
              const SizedBox(width: 6),
              Text(
                '•  ${widget.result.durationFormatted!}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isDownloading)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    value: _downloadProgress,
                    strokeWidth: 2,
                  ),
                ),
              )
            else
              IconButton(
                icon: Icon(
                  widget.isCurrent ? Icons.play_arrow : Icons.play_circle_outline,
                  color: widget.isCurrent ? theme.colorScheme.primary : null,
                ),
                tooltip: 'Stream song',
                onPressed: () => _streamAndPlay(context, controller),
              ),
            IconButton(
              icon: const Icon(Icons.more_vert),
              tooltip: 'Song options',
              onPressed: () => _showOptions(context, controller),
            ),
          ],
        ),
        onTap: () => _streamAndPlay(context, controller),
      ),
    );
  }
}
