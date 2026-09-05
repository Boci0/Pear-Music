import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import 'playlist_actions.dart';

/// One row in the library: artwork, title, meta, play button + a menu with
/// "Add to playlist" and "Remove song".
class SongTile extends StatelessWidget {
  final Song song;
  final List<Song>? queue;
  final String? sourceId;
  final String? sourceTitle;
  final bool isCurrent;
  final bool isSelecting;
  final bool isSelected;
  final ValueChanged<bool?>? onSelectionChanged;
  final VoidCallback? onLongPress;

  const SongTile({
    super.key,
    required this.song,
    this.queue,
    this.sourceId,
    this.sourceTitle,
    this.isCurrent = false,
    this.isSelecting = false,
    this.isSelected = false,
    this.onSelectionChanged,
    this.onLongPress,
  });

  Future<void> _showMenu(BuildContext context) async {
    final controller = context.read<AppController>();
    final isFav = controller.isFavorite(song.id);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(ctx).textTheme.titleSmall),
              dense: true,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.sensors_rounded),
              title: const Text('Start Radio'),
              onTap: () => Navigator.pop(ctx, 'radio'),
            ),
            if (song.sourceDeviceId == 'stream')
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('Save to library'),
                onTap: () => Navigator.pop(ctx, 'save_stream'),
              ),
            ListTile(
              leading: Icon(
                isFav ? Icons.favorite : Icons.favorite_border,
                color: isFav ? Theme.of(ctx).colorScheme.primary : null,
              ),
              title: Text(isFav ? 'Remove from favorites' : 'Add to favorites'),
              onTap: () => Navigator.pop(ctx, 'favorite'),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('Add to playlist'),
              onTap: () => Navigator.pop(ctx, 'playlist'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy title'),
              onTap: () => Navigator.pop(ctx, 'copy_title'),
            ),
            if (song.sourceDeviceId != 'stream')
              ListTile(
                leading: Icon(Icons.delete_outline,
                    color: Theme.of(ctx).colorScheme.error),
                title: Text('Remove from library',
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'radio') {
      await controller.startRadio(song);
    } else if (action == 'save_stream') {
      await controller.saveStreamToLibrary(song);
    } else if (action == 'favorite') {
      await controller.toggleFavorite(song.id);
    } else if (action == 'playlist') {
      await showAddToPlaylistSheet(context, controller, song);
    } else if (action == 'copy_title') {
      await Clipboard.setData(ClipboardData(text: song.title));
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Copied "${song.title}" to clipboard'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else if (action == 'remove') {
      await _confirmRemove(context, controller);
    }
  }

  Future<void> _confirmRemove(
    BuildContext context,
    AppController controller,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${song.title}"?'),
        content: const Text(
          'This deletes the song from this device and removes it from any '
          'playlists. Paired devices keep their own copy.',
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
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await controller.removeSong(song);
    }
  }

  @override

  Widget build(BuildContext context) {
    final isFav = context.select<AppController, bool>((c) => c.isFavorite(song.id));
    final controller = context.read<AppController>();
    final theme = Theme.of(context);
    final fromPeer = song.sourceDeviceId != null;

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              if (isSelecting) {
                onSelectionChanged?.call(!isSelected);
              } else {
                controller.playSong(
                  song,
                  queue: queue,
                  sourceId: sourceId,
                  sourceTitle: sourceTitle,
                );
              }
            },
            onLongPress:
                isSelecting ? null : (onLongPress ?? () => _showMenu(context)),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: isCurrent
                    ? LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          theme.colorScheme.primary.withValues(alpha: 0.16),
                          theme.colorScheme.primary.withValues(alpha: 0.02),
                        ],
                      )
                    : null,
                color: isSelected
                    ? theme.colorScheme.primaryContainer.withValues(alpha: 0.22)
                    : null,
                border: isCurrent
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
                    if (isCurrent)
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
                          if (isSelecting) ...[
                            Checkbox(
                              value: isSelected,
                              onChanged: onSelectionChanged,
                            ),
                            const SizedBox(width: 6),
                          ],
                          _Artwork(song: song, isCurrent: isCurrent),
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
                                    fontSize: 14.5,
                                    fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
                                    color: isCurrent ? theme.colorScheme.primary : null,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    if (song.sourceDeviceId == 'stream') ...[
                                      Icon(Icons.sensors_rounded,
                                          size: 13, color: theme.colorScheme.tertiary),
                                      const SizedBox(width: 4),
                                    ] else if (fromPeer) ...[
                                      Icon(Icons.cloud_done_outlined,
                                          size: 13, color: theme.colorScheme.primary),
                                      const SizedBox(width: 4),
                                    ],
                                    Expanded(
                                      child: Text(
                                        song.sourceDeviceId == 'stream'
                                            ? 'Radio Stream'
                                            : fromPeer
                                                ? 'Shared · ${song.sizeLabel}'
                                                : 'Local · ${song.sizeLabel}',
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
                          if (isCurrent) ...[
                            Icon(
                              Icons.graphic_eq_rounded,
                              size: 18,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                          ],
                          if (!isSelecting && isFav) ...[
                            _ActionButton(
                              icon: Icons.favorite,
                              color: theme.colorScheme.primary,
                              tooltip: 'Favorite',
                              onPressed: () => controller.toggleFavorite(song.id),
                            ),
                          ],
                          if (!isSelecting) ...[
                            _ActionButton(
                              icon: Icons.more_vert,
                              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                              tooltip: 'More options',
                              onPressed: () => _showMenu(context),
                            ),
                          ],
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

class _Artwork extends StatelessWidget {
  final Song song;
  final bool isCurrent;

  const _Artwork({required this.song, required this.isCurrent});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initialBytes = ArtworkPalette.cachedBytes(song);
    // Async decode: base64-decoding artwork on the UI thread for every tile
    // that scrolls into view janks scrolling on large libraries. The result
    // is cached per song, so this future resolves instantly after first load.
    final isNetwork = song.artwork != null && song.artwork!.startsWith('http');
    final Widget image;
    if (isNetwork) {
      image = RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(
            song.artwork!,
            key: ValueKey('tile_net_${song.id}'),
            width: 44,
            height: 44,
            cacheWidth: 96,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _placeholder(scheme),
          ),
        ),
      );
    } else if (initialBytes != null && initialBytes.isNotEmpty) {
      image = RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            initialBytes,
            key: ValueKey('tile_mem_${song.id}'),
            width: 44,
            height: 44,
            cacheWidth: 96,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _placeholder(scheme),
          ),
        ),
      );
    } else {
      image = RepaintBoundary(
        child: FutureBuilder<Uint8List?>(
          key: ValueKey('tile_async_${song.id}'),
          initialData: initialBytes,
          future: ArtworkPalette.bytesAsync(song),
          builder: (context, snapshot) {
            final bytes = snapshot.data ?? initialBytes;
            if (bytes == null || bytes.isEmpty) return _placeholder(scheme);
            return ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                bytes,
                key: ValueKey('tile_mem_${song.id}'),
                width: 44,
                height: 44,
                cacheWidth: 96,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _placeholder(scheme),
              ),
            );
          },
        ),
      );
    }
    if (!isCurrent) return image;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.65),
          width: 1.5,
        ),
      ),
      child: image,
    );
  }

  Widget _placeholder(ColorScheme scheme) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
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
        isCurrent ? Icons.music_note : Icons.audiotrack,
        color: scheme.onPrimaryContainer,
        size: 22,
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: Icon(icon, size: 19, color: color),
            ),
          ),
        ),
      ),
    );
  }
}
