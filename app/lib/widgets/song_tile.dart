import 'dart:typed_data';

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
    final controller = context.watch<AppController>();
    final theme = Theme.of(context);
    final fromPeer = song.sourceDeviceId != null;
    final isFav = controller.isFavorite(song.id);

    return ListTile(
      selected: isSelected,
      tileColor: isCurrent
          ? (theme.brightness == Brightness.dark
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.28)
              : theme.colorScheme.primaryContainer.withValues(alpha: 0.40))
          : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
          if (song.sourceDeviceId == 'stream') ...[
            Icon(Icons.sensors_rounded,
                size: 14, color: theme.colorScheme.tertiary),
            const SizedBox(width: 4),
          ] else if (fromPeer) ...[
            Icon(Icons.cloud_done_outlined,
                size: 14, color: theme.colorScheme.primary),
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
                if (isFav)
                  IconButton(
                    iconSize: 20,
                    tooltip: 'Favorite',
                    icon: Icon(Icons.favorite, color: theme.colorScheme.primary),
                    onPressed: () => controller.toggleFavorite(song.id),
                  ),
                if (isCurrent)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _EqualizerBars(
                      isPlaying: controller.player.playing,
                      color: theme.colorScheme.primary,
                    ),
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
          controller.playSong(
            song,
            queue: queue,
            sourceId: sourceId,
            sourceTitle: sourceTitle,
          );
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
    final initialBytes = ArtworkPalette.bytes(song);
    // Async decode: base64-decoding artwork on the UI thread for every tile
    // that scrolls into view janks scrolling on large libraries. The result
    // is cached per song, so this future resolves instantly after first load.
    final isNetwork = song.artwork != null && song.artwork!.startsWith('http');
    final Widget image = isNetwork
        ? ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(
              song.artwork!,
              width: 44,
              height: 44,
              cacheWidth: 88,
              cacheHeight: 88,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _placeholder(scheme),
            ),
          )
        : FutureBuilder<Uint8List?>(
            initialData: initialBytes,
            future: ArtworkPalette.bytesAsync(song),
            builder: (context, snapshot) {
              final bytes = snapshot.data ?? initialBytes;
              if (bytes == null || bytes.isEmpty) return _placeholder(scheme);
              return ClipRRect(
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
              );
            },
          );
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

/// Dynamic 3-bar equalizer visualizer that animates smoothly when audio is playing.
class _EqualizerBars extends StatefulWidget {
  final bool isPlaying;
  final Color color;

  const _EqualizerBars({
    required this.isPlaying,
    required this.color,
  });

  @override
  State<_EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<_EqualizerBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    );
    if (widget.isPlaying) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _EqualizerBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _controller.repeat(reverse: true);
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final h1 = widget.isPlaying ? 5.0 + 9.0 * (0.5 + 0.5 * (t * 2 - 1).abs()) : 6.0;
        final h2 = widget.isPlaying ? 4.0 + 12.0 * t : 12.0;
        final h3 = widget.isPlaying ? 5.0 + 8.0 * (1.0 - t) : 8.0;

        return SizedBox(
          width: 18,
          height: 18,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _buildBar(h1),
              _buildBar(h2),
              _buildBar(h3),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBar(double height) {
    return Container(
      width: 3.5,
      height: height.clamp(3.0, 16.0),
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

