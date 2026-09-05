import 'package:flutter/material.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/player_service.dart';
import 'player_artwork.dart';
import 'player_controls.dart';

/// Landscape mobile layout: 2-column split with artwork on the left and
/// transport/volume controls on the right.
class PlayerLandscapeBody extends StatelessWidget {
  final AppController controller;
  final PlayerService player;
  final Song song;
  final Duration duration;
  final Color accent;

  const PlayerLandscapeBody({
    super.key,
    required this.controller,
    required this.player,
    required this.song,
    required this.duration,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final artSize = (constraints.maxHeight * 0.6).clamp(120.0, 340.0);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
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
                          PlayerArtworkHero(
                            song: song,
                            size: artSize,
                            artwork: ArtworkPalette.cachedBytes(song),
                            accent: accent,
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
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: PlayerSeekBar(
                          player: player,
                          duration: duration,
                        ),
                      ),
                      const SizedBox(height: 12),
                      PlayerTransport(player: player, controller: controller),
                      const SizedBox(height: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: const PlayerVolumeRow(),
                      ),
                    ],
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