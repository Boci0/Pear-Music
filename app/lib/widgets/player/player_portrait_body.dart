import 'package:flutter/material.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/player_service.dart';
import 'player_artwork.dart';
import 'player_controls.dart';

/// Portrait mobile body: vertically centered artwork, track details, and
/// playback controls.
class PlayerPortraitBody extends StatelessWidget {
  final AppController controller;
  final PlayerService player;
  final Song song;
  final Duration duration;
  final Color accent;

  const PlayerPortraitBody({
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
        final availableHeight = constraints.maxHeight;
        final artSize = (availableHeight * 0.42).clamp(160.0, 360.0);

        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: availableHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Center(
                  child: PlayerArtworkHero(
                    song: song,
                    size: artSize,
                    artwork: ArtworkPalette.bytes(song),
                    accent: accent,
                  ),
                ),
                PlayerSongInfo(song: song),
                PlayerSeekBar(player: player, duration: duration),
                PlayerTransport(player: player, controller: controller),
                const PlayerVolumeRow(),
              ],
            ),
          ),
        );
      },
    );
  }
}