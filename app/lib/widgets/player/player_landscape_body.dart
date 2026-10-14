import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/player_service.dart';
import '../../services/video_service.dart';
import 'player_artwork.dart';
import 'player_controls.dart';
import 'player_video_view.dart';

/// Landscape mobile layout: 2-column split with artwork on the left and
/// transport/volume controls on the right.
class PlayerLandscapeBody extends StatelessWidget {
  final AppController controller;
  final PlayerService player;
  final Song song;
  final Duration duration;
  final Color accent;

  /// Opens the queue. Set where the screen has no pull-up queue sheet or side
  /// panel (a phone held sideways), which shows a labelled button under the
  /// volume row.
  final VoidCallback? onOpenQueue;

  const PlayerLandscapeBody({
    super.key,
    required this.controller,
    required this.player,
    required this.song,
    required this.duration,
    required this.accent,
    this.onOpenQueue,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final artSize = (constraints.maxHeight * 0.52).clamp(150.0, 400.0);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1500),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(
                  flex: 5,
                  child: Center(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (context.watch<VideoService?>()?.showingFor(
                                song,
                              ) ??
                              false)
                            PlayerVideoView(
                              accent: accent,
                              maxWidth: constraints.maxWidth * 5 / 9 - 24,
                              maxHeight: constraints.maxHeight * 0.62,
                            )
                          else
                            PlayerArtworkHero(
                              song: song,
                              size: artSize,
                              artwork: ArtworkPalette.cachedBytes(song),
                              accent: accent,
                              videoEnabled: true,
                            ),
                          const SizedBox(height: 20),
                          PlayerSongInfo(song: song),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Center(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 480),
                            child: PlayerSeekBar(
                              player: player,
                              duration: duration,
                              accent: accent,
                            ),
                          ),
                          const SizedBox(height: 12),
                          PlayerTransport(
                            player: player,
                            controller: controller,
                            accent: accent,
                          ),
                          const SizedBox(height: 12),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 480),
                            child: PlayerVolumeRow(accent: accent),
                          ),
                          if (onOpenQueue != null) ...[
                            const SizedBox(height: 4),
                            TextButton.icon(
                              key: const ValueKey('up_next_button'),
                              onPressed: onOpenQueue,
                              icon: const Icon(Icons.queue_music_rounded),
                              label: const Text('Up Next'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
