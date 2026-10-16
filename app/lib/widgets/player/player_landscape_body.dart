import 'dart:math' as math;

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

  /// A short screen (a phone held sideways): the title and song buttons live
  /// in the top bar, so the card takes the whole height and the volume row
  /// goes (a phone has volume keys).
  final bool compact;

  const PlayerLandscapeBody({
    super.key,
    required this.controller,
    required this.player,
    required this.song,
    required this.duration,
    required this.accent,
    this.onOpenQueue,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The artwork (and the lyrics in it) take what the title block under
        // it leaves: bigger on a tablet or a car screen, the old 52% floor on
        // a phone held sideways. Never wider than its column.
        final column = constraints.maxWidth * 5 / 9 - 48;
        final artSize = (compact
                ? constraints.maxHeight - 8
                : math.max(
                    constraints.maxHeight * 0.52,
                    constraints.maxHeight - 150,
                  ))
            .clamp(150.0, 560.0)
            .clamp(0.0, math.max(150.0, column))
            .toDouble();
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
                          Builder(
                            builder: (context) {
                              final showVideo =
                                  context.watch<VideoService?>()?.showingFor(
                                    song,
                                  ) ??
                                  false;
                              return PlayerPictureSwap(
                                video: showVideo,
                                child: showVideo
                                    ? PlayerVideoView(
                                        accent: accent,
                                        maxWidth:
                                            constraints.maxWidth * 5 / 9 - 24,
                                        maxHeight: compact
                                            ? constraints.maxHeight - 8
                                            : math.max(
                                                constraints.maxHeight * 0.62,
                                                constraints.maxHeight - 150,
                                              ),
                                      )
                                    : PlayerArtworkHero(
                                        song: song,
                                        size: artSize,
                                        artwork: ArtworkPalette.cachedBytes(
                                          song,
                                        ),
                                        accent: accent,
                                        videoEnabled: true,
                                      ),
                              );
                            },
                          ),
                          if (!compact) ...[
                            const SizedBox(height: 20),
                            PlayerSongInfo(song: song),
                          ],
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
                          if (!compact) ...[
                            const SizedBox(height: 12),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 480),
                              child: PlayerVolumeRow(accent: accent),
                            ),
                          ],
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
