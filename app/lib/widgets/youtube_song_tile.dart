import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/youtube_search_service.dart';

/// A list tile representing a YouTube search result with tap-to-download-and-play.
class YouTubeSongTile extends StatefulWidget {
  final YouTubeSearchResult result;
  final bool isCurrent;

  const YouTubeSongTile({
    super.key,
    required this.result,
    this.isCurrent = false,
  });

  @override
  State<YouTubeSongTile> createState() => _YouTubeSongTileState();
}

class _YouTubeSongTileState extends State<YouTubeSongTile> {
  bool _isDownloading = false;
  double? _downloadProgress;

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
                        widget.result.thumbnailUrl!,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
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
              leading: _isDownloading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_circle_outline),
              title: const Text('Download & Play'),
              subtitle: const Text('Save to library and start playback'),
              onTap: _isDownloading
                  ? null
                  : () {
                      Navigator.of(ctx).pop();
                      _downloadAndPlay(context, controller, autoPlay: true);
                    },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Download to Library only'),
              subtitle: const Text('Save for offline listening without interrupting playback'),
              onTap: _isDownloading
                  ? null
                  : () {
                      Navigator.of(ctx).pop();
                      _downloadAndPlay(context, controller, autoPlay: false);
                    },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadAndPlay(
    BuildContext context,
    AppController controller, {
    required bool autoPlay,
  }) async {
    if (_isDownloading) return;

    setState(() {
      _isDownloading = true;
      _downloadProgress = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
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

    if (mounted) {
      setState(() {
        _isDownloading = false;
        _downloadProgress = null;
      });

      if (res.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.error!), backgroundColor: Colors.redAccent),
        );
      } else if (res.song != null) {
        if (autoPlay) {
          await controller.playSong(res.song!);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Playing "${res.song!.title}"'),
                backgroundColor: Colors.teal,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Downloaded "${res.song!.title}" to library.'),
              backgroundColor: Colors.teal,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = context.read<AppController>();

    return ListTile(
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
                    errorBuilder: (_, __, ___) => Container(
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
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.equalizer, color: Colors.white, size: 24),
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
          Flexible(
            child: Text(
              widget.result.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            widget.result.durationFormatted,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
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
              icon: const Icon(Icons.download_for_offline_outlined),
              tooltip: 'Download & Play',
              onPressed: () => _downloadAndPlay(context, controller, autoPlay: true),
            ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Song options',
            onPressed: () => _showOptions(context, controller),
          ),
        ],
      ),
      onTap: () => _downloadAndPlay(context, controller, autoPlay: true),
    );
  }
}
