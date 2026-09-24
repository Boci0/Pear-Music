import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/player_service.dart';
import 'player_artwork.dart';
import 'player_controls.dart';
import 'queue_bottom_sheet.dart';

/// Very wide desktop layout: artwork column, controls column, and a permanent
/// Up Next panel filling the right side (replaces the pull-up peek sheet).
class PlayerDesktopBody extends StatelessWidget {
  final AppController controller;
  final PlayerService player;
  final Song song;
  final Duration duration;
  final Color accent;
  final double panelWidth;

  const PlayerDesktopBody({
    super.key,
    required this.controller,
    required this.player,
    required this.song,
    required this.duration,
    required this.accent,
    required this.panelWidth,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 32.0;
        final columnsWidth =
            math.max(320.0, constraints.maxWidth - panelWidth - gap * 2);
        final artColumnWidth = columnsWidth * 5 / 9;
        final artSize = math
            .min(constraints.maxHeight * 0.56, artColumnWidth - 16)
            .clamp(200.0, 560.0);

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1760),
            child: Row(
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
                const SizedBox(width: gap),
                Expanded(
                  flex: 4,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: PlayerSeekBar(
                          player: player,
                          duration: duration,
                          accent: accent,
                        ),
                      ),
                      const SizedBox(height: 16),
                      PlayerTransport(
                        player: player,
                        controller: controller,
                        accent: accent,
                      ),
                      const SizedBox(height: 16),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: PlayerVolumeRow(accent: accent),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: gap),
                SizedBox(
                  width: panelWidth,
                  child: PlayerQueuePanel(player: player, accent: accent),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
