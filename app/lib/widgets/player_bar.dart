import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../screens/player_screen.dart';
import '../services/artwork_palette.dart';
import '../services/artwork_service.dart';
import '../services/player_service.dart';
import 'pear_page_route.dart';

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
    // the colour follows the music outside the full player.
    final accent = ArtworkPalette.dominantSync(song);
    final control = ArtworkPalette.controlAccent(accent);
    final barColor =
        Color.lerp(
          theme.colorScheme.surfaceContainerHigh,
          ArtworkPalette.wash(accent, lightness: 0.14),
          0.45,
        ) ??
        theme.colorScheme.surfaceContainerHigh;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          final vx = details.primaryVelocity ?? 0;
          if (vx < -200) {
            controller.nextTrack();
          } else if (vx > 200) {
            controller.previousTrack();
          }
        },
        onVerticalDragEnd: (details) {
          final vy = details.primaryVelocity ?? 0;
          if (vy < -200) {
            _openPlayer(context);
          }
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.40),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: barColor,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: InkWell(
              onTap: () => _openPlayer(context),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _MiniPlayerBackgroundProgress(
                      player: player,
                      color: control,
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                                (player.isLoadingTrack && !player.playing)
                                    ? 'Buffering track...'
                                    : 'Playing on this device',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: (player.isLoadingTrack && !player.playing)
                                      ? theme.colorScheme.primary
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.skip_previous, color: control),
                          onPressed: () => controller.previousTrack(),
                        ),
                        SizedBox(
                          width: 36,
                          height: 36,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            iconSize: 36,
                            icon: (player.isLoadingTrack && !player.playing)
                                ? Center(
                                    child: SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        color: control,
                                      ),
                                    ),
                                  )
                                : Icon(
                                    player.playing
                                        ? Icons.pause_circle_filled
                                        : Icons.play_circle_filled,
                                    size: 36,
                                    color: control,
                                  ),
                            onPressed: () => controller.togglePlayback(),
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.skip_next, color: control),
                          onPressed: () => controller.nextTrack(),
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
);
  }

  void _openPlayer(BuildContext context) {
    Navigator.of(context).push(
      PearPageRoute(
        builder: (_) => const PlayerScreen(),
      ),
    );
  }
}

/// 40x40 artwork thumb for the now-playing bar wrapped in a Hero tag.
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
      child: Icon(
        Icons.music_note,
        color: theme.colorScheme.onPrimaryContainer,
        size: 20,
      ),
    );

    Widget imageWidget;
    if (artwork == null || artwork.isEmpty) {
      imageWidget = placeholder;
    } else if (artwork.startsWith('http')) {
      final optimized = ArtworkService.optimizeArtworkUrl(artwork);
      imageWidget = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          optimized,
          width: 40,
          height: 40,
          cacheWidth: 100,
          
          fit: BoxFit.cover,
          alignment: Alignment.center,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => Image.network(
            artwork,
            width: 40,
            height: 40,
            cacheWidth: 100,
            
            fit: BoxFit.cover,
            alignment: Alignment.center,
            errorBuilder: (_, _, _) => placeholder,
          ),
        ),
      );
    } else {
      final bytes = ArtworkPalette.bytes(song);
      if (bytes == null || bytes.isEmpty) {
        imageWidget = placeholder;
      } else {
        imageWidget = ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            bytes,
            width: 40,
            height: 40,
            cacheWidth: 96,
            
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
          ),
        );
      }
    }

    return Hero(
      tag: 'player_artwork_${song.id}',
      child: Material(type: MaterialType.transparency, child: imageWidget),
    );
  }
}

/// Progress fill spanning the entire mini player capsule background from left to right.
class _MiniPlayerBackgroundProgress extends StatelessWidget {
  final PlayerService player;
  final Color color;
  const _MiniPlayerBackgroundProgress({
    required this.player,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: StreamBuilder<Duration?>(
        stream: player.durationStream,
        initialData: player.duration,
        builder: (context, durSnapshot) {
          final totalMs =
              (durSnapshot.data ?? player.duration ?? Duration.zero)
                  .inMilliseconds
                  .toDouble();
          if (totalMs <= 0) {
            return const SizedBox.expand();
          }
          return StreamBuilder<Duration>(
            stream: player.positionStream,
            initialData: player.position ?? Duration.zero,
            builder: (context, posSnapshot) {
              final posMs =
                  (posSnapshot.data ?? player.position ?? Duration.zero)
                      .inMilliseconds
                      .toDouble();
              final fraction = (posMs / totalMs).clamp(0.0, 1.0);
              return FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: fraction,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        color.withValues(alpha: 0.22),
                        color.withValues(alpha: 0.12),
                      ],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                    border: Border(
                      right: BorderSide(
                        color: color.withValues(alpha: 0.50),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

