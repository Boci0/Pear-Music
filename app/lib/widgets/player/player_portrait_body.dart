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
        // The card (and the lyrics in it) uses the page's full width less its
        // side padding; the 480 cap only matters on a tablet held upright.
        final maxByWidth = (constraints.maxWidth - 48.0).clamp(150.0, 480.0);
        final maxByHeight = (availableHeight - peekHeight - 250.0).clamp(120.0, 480.0);
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
                    child: Builder(
                      builder: (context) {
                        final showVideo =
                            context.watch<VideoService?>()?.showingFor(song) ??
                            false;
                        return PlayerPictureSwap(
                          video: showVideo,
                          // The picture takes the artwork's place, as wide as
                          // the page allows in its own shape.
                          child: showVideo
                              ? PlayerVideoView(
                                  accent: accent,
                                  maxWidth: constraints.maxWidth - 48,
                                  maxHeight: math.max(artSize, 180),
                                )
                              : PlayerArtworkHero(
                                  song: song,
                                  size: artSize,
                                  artwork: ArtworkPalette.cachedBytes(song),
                                  accent: accent,
                                  videoEnabled: true,
                                ),
                        );
                      },
                    ),
                  ),
                  PlayerSongInfo(song: song),
                  PlayerSeekBar(
                    player: player,
                    duration: duration,
                    accent: accent,
                  ),
                  PlayerTransport(
                    player: player,
                    controller: controller,
                    accent: accent,
                  ),
                  PlayerVolumeRow(accent: accent),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}