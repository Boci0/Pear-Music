import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';

/// Large album artwork container with rounded corners and ambient accent glow.
class PlayerArtwork extends StatelessWidget {
  final Uint8List? artwork;
  final String? networkUrl;
  final double size;
  final Color? accent;
  const PlayerArtwork({
    super.key,
    this.artwork,
    this.networkUrl,
    this.size = 240,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(16);
    final shadowColor = (accent ?? scheme.primary).withValues(alpha: 0.35);

    return RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: shadowColor,
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
      child: ClipRRect(
        borderRadius: radius,
        child: networkUrl != null && networkUrl!.isNotEmpty
            ? Image.network(
                networkUrl!,
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _placeholder(scheme),
              )
            : artwork != null && artwork!.isNotEmpty
                ? Image.memory(
                    artwork!,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  )
                : _placeholder(scheme),
        ),
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) {
    return Container(
      width: size,
      height: size,
      color: scheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        size: size * 0.45,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// Artwork wrapped in a Hero tag to animate from the bottom bar into the
/// player screen.
class PlayerArtworkHero extends StatelessWidget {
  final Song song;
  final Uint8List? artwork;
  final double size;
  final Color? accent;

  const PlayerArtworkHero({
    super.key,
    required this.song,
    this.artwork,
    this.size = 240,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final isNetwork = song.artwork != null && song.artwork!.startsWith('http');
    return Hero(
      tag: 'player_artwork_${song.id}',
      child: Material(
        type: MaterialType.transparency,
        child: PlayerArtwork(
          artwork: isNetwork ? null : artwork,
          networkUrl: isNetwork ? song.artwork : null,
          size: size,
          accent: accent,
        ),
      ),
    );
  }
}

/// Song title, artist/device info line, and favorite toggle button.
class PlayerSongInfo extends StatelessWidget {
  final Song song;
  const PlayerSongInfo({super.key, required this.song});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final isFav = controller.isFavorite(song.id);
    final theme = Theme.of(context);

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (song.sourceDeviceId == 'stream')
              IconButton(
                icon: Icon(
                  Icons.download_rounded,
                  color: theme.colorScheme.tertiary,
                ),
                tooltip: 'Save to library',
                onPressed: () => controller.saveStreamToLibrary(song),
              )
            else
              IconButton(
                icon: Icon(
                  Icons.sensors_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                tooltip: 'Start Radio mix',
                onPressed: () => controller.startRadio(song),
              ),
            Expanded(
              child: Text(
                song.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall,
              ),
            ),
            IconButton(
              icon: Icon(
                isFav ? Icons.favorite : Icons.favorite_border,
                color: isFav
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              tooltip: isFav ? 'Remove from favorites' : 'Add to favorites',
              onPressed: () => controller.toggleFavorite(song.id),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          song.sourceDeviceId == 'stream'
              ? 'Radio Stream'
              : song.sourceDeviceId == null
                  ? 'Added on this device'
                  : 'Shared',
          style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}
