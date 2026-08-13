import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import 'playlist_actions.dart';

/// One row in the library: artwork, title, meta, play button + a menu with
/// "Add to playlist" and "Remove song".
class SongTile extends StatelessWidget {
  final Song song;
  final bool isCurrent;
  final bool isSelecting;
  final bool isSelected;
  final ValueChanged<bool?>? onSelectionChanged;
  final VoidCallback? onLongPress;

  const SongTile({
    super.key,
    required this.song,
    this.isCurrent = false,
    this.isSelecting = false,
    this.isSelected = false,
    this.onSelectionChanged,
    this.onLongPress,
  });

  Future<void> _showMenu(BuildContext context) async {
    final controller = context.read<AppController>();
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
              leading: const Icon(Icons.playlist_add),
              title: const Text('Add to playlist'),
              onTap: () => Navigator.pop(ctx, 'playlist'),
            ),
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
    if (action == 'playlist') {
      await showAddToPlaylistSheet(context, controller, song);
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
    final controller = context.read<AppController>();
    final theme = Theme.of(context);
    final fromPeer = song.sourceDeviceId != null;

    return ListTile(
      selected: isSelected,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSelecting)
            Checkbox(
              value: isSelected,
              onChanged: onSelectionChanged,
            ),
          _Artwork(song: song, isCurrent: isCurrent),
        ],
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
          color: isCurrent ? theme.colorScheme.primary : null,
        ),
      ),
      subtitle: Row(
        children: [
          if (fromPeer) ...[
            Icon(Icons.cloud_done_outlined,
                size: 14, color: theme.colorScheme.primary),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              fromPeer
                  ? 'Shared · ${song.sizeLabel}'
                  : 'Local · ${song.sizeLabel}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
      trailing: isSelecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isCurrent)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(Icons.graphic_eq,
                        color: theme.colorScheme.primary),
                  ),
                IconButton(
                  tooltip: 'More options',
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => _showMenu(context),
                ),
              ],
            ),
      onTap: () {
        if (isSelecting) {
          onSelectionChanged?.call(!isSelected);
        } else {
          controller.playSong(song);
        }
      },
      onLongPress: isSelecting ? null : (onLongPress ?? () => _showMenu(context)),
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
    final bytes = ArtworkPalette.bytes(song);
    final Widget image = bytes != null
        ? ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              bytes,
              width: 44,
              height: 44,
              // Decode at ~2x display size instead of the full 256px JPEG:
              // much less RAM per tile in a long library list.
              cacheWidth: 88,
              cacheHeight: 88,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _placeholder(scheme),
            ),
          )
        : _placeholder(scheme);
    if (!isCurrent) return image;
    final accent = ArtworkPalette.dominantSync(song);
    return Container(
      width: 48,
      height: 48,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: ArtworkPalette.controlAccent(accent),
          width: 2,
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
