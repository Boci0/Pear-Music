import 'package:flutter/material.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/player_service.dart';
import 'player_artwork.dart';
import 'player_controls.dart';
import 'queue_bottom_sheet.dart';

/// Portrait mobile body: vertically centered artwork, track details, playback
/// controls, and YouTube Music style pull-up queue peek card.
class PlayerPortraitBody extends StatefulWidget {
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
  State<PlayerPortraitBody> createState() => _PlayerPortraitBodyState();
}

class _PlayerPortraitBodyState extends State<PlayerPortraitBody> {
  final QueueSheetController _sheetController = QueueSheetController();

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight;
        final bottomInset = MediaQuery.paddingOf(context).bottom;
        final peekHeight = 62.0 + bottomInset;
        final minChildSize = (peekHeight / availableHeight).clamp(0.06, 0.22);
        final maxHeight = availableHeight * 0.50;
        final artSize =
            ((availableHeight - peekHeight) * 0.36).clamp(140.0, 320.0);

        return Stack(
          children: [
            // 1. Underlying Player Content (artwork, seekbar, controls, volume)
            Positioned.fill(
              child: RepaintBoundary(
                child: SingleChildScrollView(
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
                            song: widget.song,
                            size: artSize,
                            artwork: ArtworkPalette.bytes(widget.song),
                            accent: widget.accent,
                          ),
                        ),
                        PlayerSongInfo(song: widget.song),
                        PlayerSeekBar(
                          player: widget.player,
                          duration: widget.duration,
                        ),
                        PlayerTransport(
                          player: widget.player,
                          controller: widget.controller,
                        ),
                        const PlayerVolumeRow(),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // 2. Dimming Scrim when sheet is expanded (tap outside to collapse)
            Positioned.fill(
              child: ListenableBuilder(
                listenable: _sheetController,
                builder: (context, _) {
                  final progress = _sheetController.progress;

                  return IgnorePointer(
                    ignoring: progress <= 0.001,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _sheetController.collapse,
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.55 * progress),
                      ),
                    ),
                  );
                },
              ),
            ),

            // 3. YouTube Music Style Real-Time Expandable Queue Sheet
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: RepaintBoundary(
                child: ExpandableQueueSheet(
                  player: widget.player,
                  controller: widget.controller,
                  accent: widget.accent,
                  minChildSize: minChildSize,
                  peekHeight: peekHeight,
                  maxHeight: maxHeight,
                  sheetController: _sheetController,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}