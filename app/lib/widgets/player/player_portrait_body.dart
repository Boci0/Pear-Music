import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/player_service.dart';
import 'player_artwork.dart';
import 'player_controls.dart';

/// Portrait mobile body: vertically centered artwork, track details, playback
/// controls, and bottom padding for the pull-up queue peek card.
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
        final bottomInset = MediaQuery.paddingOf(context).bottom;
        final peekHeight = 62.0 + bottomInset;
        // Allow artwork to sit comfortably with balanced margins
        // while bounding against available vertical space to prevent transport controls from being cramped.
        final maxByWidth = (constraints.maxWidth - 72.0).clamp(150.0, 305.0);
        final maxByHeight = (availableHeight - peekHeight - 250.0).clamp(150.0, 305.0);
        final artSize = math.min(maxByWidth, maxByHeight);

        return RepaintBoundary(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            clipBehavior: Clip.none,
            padding: EdgeInsets.fromLTRB(24, 8, 24, peekHeight + 12),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight:
                    (availableHeight - peekHeight - 20).clamp(0.0, double.infinity),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Center(
                    child: PlayerArtworkHero(
                      song: song,
                      size: artSize,
                      artwork: ArtworkPalette.cachedBytes(song),
                      accent: accent,
                    ),
                  ),
                  PlayerSongInfo(song: song),
                  PlayerSeekBar(
                    player: player,
                    duration: duration,
                  ),
                  PlayerTransport(
                    player: player,
                    controller: controller,
                  ),
                  const PlayerVolumeRow(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}