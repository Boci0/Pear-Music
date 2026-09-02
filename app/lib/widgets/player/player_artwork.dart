import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/player_service.dart';
import 'player_console_dialog.dart';

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
        cacheHeight: 384,
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
        cacheHeight: 384,
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
            cacheHeight: 384,
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
        _buildSourceInfo(
          context,
          isStream,
          route,
          player.isLoadingTrack && !player.playing,
          scheme,
          theme,
        ),
      ],
    );
  }

  Widget _buildSourceInfo(
    BuildContext context,
    bool isStream,
    StreamRouteType route,
    bool isConnecting,
    ColorScheme scheme,
    ThemeData theme,
  ) {
    final Widget content;

    if (isStream && isConnecting) {
      content = Row(
        key: const ValueKey('source_buffering'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 8,
            height: 8,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Connecting to Pear Radio...',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    } else if (isStream) {
      content = GestureDetector(
        key: const ValueKey('source_stream'),
        onLongPress: () => PlayerConsoleDialog.show(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.radio_rounded,
              size: 14,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 5),
            Text(
              'Pear Radio',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    } else {
      final label = song.sourceDeviceId == null ? 'Local Library' : 'Shared from peer';
      content = Row(
        key: ValueKey('source_local_${song.id}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            song.sourceDeviceId == null ? Icons.folder_outlined : Icons.devices_rounded,
            size: 14,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: content,
    );
  }
}

