import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../screens/player_screen.dart';
import '../services/artwork_palette.dart';
import '../services/player_service.dart';

/// Compact now-playing bar shown above the navigation bar.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    // Watch only the player so this bar rebuilds on playback state changes
    // (rare) and not on library/connection/transfer updates.
    final player = context.watch<PlayerService>();
    final song = player.currentSong;
    if (song == null) return const SizedBox.shrink();
    final controller = context.read<AppController>();
    final theme = Theme.of(context);

    // Carry the current song's artwork colour into the mini player too, so
    // the colour follows the music outside the full player. Subtle: a slight
    // tint on the bar + the transport buttons take the softened accent.
    return FutureBuilder<Color>(
      future: ArtworkPalette.dominant(song),
      builder: (context, snapshot) {
        final accent = snapshot.data ?? ArtworkPalette.fallback;
        final control = ArtworkPalette.controlAccent(accent);
        final barColor = Color.lerp(
              theme.colorScheme.surfaceContainerHigh,
              ArtworkPalette.wash(accent, lightness: 0.14),
              0.45,
            ) ??
            theme.colorScheme.surfaceContainerHigh;
        return Material(
          color: barColor,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlayerScreen()),
            ),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  _Thumb(song: song),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          'Playing on this device',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.skip_previous, color: control),
                    onPressed: () => controller.previousTrack(),
                  ),
                  IconButton(
                    icon: Icon(
                      player.playing
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled,
                      size: 36,
                      color: control,
                    ),
                    onPressed: () => controller.togglePlayback(),
                  ),
                  IconButton(
                    icon: Icon(Icons.skip_next, color: control),
                    onPressed: () => controller.nextTrack(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 40×40 artwork thumb for the now-playing bar: scraped artwork when the song
/// has it, otherwise the gradient + note placeholder.
class _Thumb extends StatelessWidget {
  final Song song;
  const _Thumb({required this.song});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artwork = song.artwork;
    final placeholder = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primaryContainer,
            theme.colorScheme.primary.withValues(alpha: 0.6),
          ],
        ),
      ),
      child: Icon(Icons.music_note,
          color: theme.colorScheme.onPrimaryContainer, size: 20),
    );
    if (artwork == null || artwork.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(
        ArtworkPalette.bytes(song)!,
        width: 40,
        height: 40,
        cacheWidth: 80,
        cacheHeight: 80,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}
