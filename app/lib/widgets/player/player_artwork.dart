import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/player_service.dart';

/// Large album artwork container with rounded corners and ambient accent glow.
class PlayerArtwork extends StatelessWidget {
  final Song? song;
  final Uint8List? artwork;
  final String? networkUrl;
  final double size;
  final Color? accent;
  const PlayerArtwork({
    super.key,
    this.song,
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

    final songArt = song?.artwork;
    final isNetwork = networkUrl != null || (songArt != null && songArt.startsWith('http'));
    final effectiveNetworkUrl = networkUrl ?? (isNetwork ? songArt : null);
    final initialBytes = artwork ?? (song != null ? ArtworkPalette.bytes(song!) : null);

    final Widget imageWidget;
    if (effectiveNetworkUrl != null && effectiveNetworkUrl.isNotEmpty) {
      imageWidget = Image.network(
        effectiveNetworkUrl,
        key: ValueKey('net_$effectiveNetworkUrl'),
        width: size,
        height: size,
        cacheWidth: 384,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(scheme),
      );
    } else if (initialBytes != null && initialBytes.isNotEmpty) {
      imageWidget = Image.memory(
        initialBytes,
        key: ValueKey('mem_${song?.id ?? initialBytes.hashCode}'),
        width: size,
        height: size,
        cacheWidth: 384,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    } else if (song != null) {
      imageWidget = FutureBuilder<Uint8List?>(
        key: ValueKey('async_${song!.id}'),
        future: ArtworkPalette.bytesAsync(song!),
        initialData: initialBytes,
        builder: (context, snapshot) {
          final bytes = snapshot.data ?? initialBytes;
          if (bytes == null || bytes.isEmpty) return _placeholder(scheme);
          return Image.memory(
            bytes,
            width: size,
            height: size,
            cacheWidth: 384,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          );
        },
      );
    } else {
      imageWidget = _placeholder(scheme);
    }

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
          child: imageWidget,
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
          key: ValueKey('hero_art_${song.id}'),
          song: song,
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
    final player = context.watch<PlayerService>();
    final isFav = controller.isFavorite(song.id);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isStream = song.sourceDeviceId == 'stream';
    final route = player.currentRouteType;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isStream)
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
        const SizedBox(height: 6),
        if (isStream)
          _buildLoadTimeBadge(player.lastTrackLoadMs, route, player.isLoadingTrack, scheme)
        else
          Text(
            song.sourceDeviceId == null
                ? 'Added on this device'
                : 'Shared from peer',
            style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
          ),
      ],
    );
  }

  Widget _buildLoadTimeBadge(int loadMs, StreamRouteType route, bool isLoading, ColorScheme scheme) {
    if (isLoading || loadMs < 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: scheme.primary.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              'Buffering...',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      );
    }

    final String label;
    final IconData icon;
    final Color color;
    final Color bg;

    if (route == StreamRouteType.cached) {
      label = loadMs <= 0 ? '0 ms' : '$loadMs ms';
      icon = Icons.bolt_rounded;
      color = const Color(0xFF81C784);
      bg = const Color(0xFF1B2E1D);
    } else if (loadMs < 1000) {
      label = '$loadMs ms';
      icon = Icons.timer_outlined;
      color = scheme.primary;
      bg = scheme.primary.withValues(alpha: 0.15);
    } else {
      label = '${(loadMs / 1000).toStringAsFixed(1)} s';
      icon = Icons.cloud_download_outlined;
      color = const Color(0xFFFFB74D);
      bg = const Color(0xFF332005);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

