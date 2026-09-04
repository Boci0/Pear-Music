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
        final artSize = (availableHeight * 0.36).clamp(140.0, 320.0);

        return Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (availableHeight - 64).clamp(0.0, double.infinity),
                  ),
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
              ),
            ),
            QueuePullUpCard(
              player: player,
              controller: controller,
              accent: accent,
            ),
          ],
        );
      },
    );
  }
}

class QueuePullUpCard extends StatefulWidget {
  final PlayerService player;
  final AppController controller;
  final Color accent;

  const QueuePullUpCard({
    super.key,
    required this.player,
    required this.controller,
    required this.accent,
  });

  @override
  State<QueuePullUpCard> createState() => _QueuePullUpCardState();
}

class _QueuePullUpCardState extends State<QueuePullUpCard> {
  double _dragDistance = 0.0;

  void _openQueue() {
    QueueBottomSheet.show(
      context,
      player: widget.player,
      controller: widget.controller,
      accent: widget.accent,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.player,
      builder: (context, _) {
        final queue = widget.player.queue;
        final nextIndex = widget.player.queueIndex + 1;
        final nextSong = (nextIndex < queue.length) ? queue[nextIndex] : null;
        final bottomInset = MediaQuery.paddingOf(context).bottom;

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openQueue,
            onVerticalDragStart: (_) => _dragDistance = 0.0,
            onVerticalDragUpdate: (details) {
              _dragDistance += details.primaryDelta ?? 0.0;
            },
            onVerticalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0.0;
              // Trigger if dragged upwards by more than 15px OR flicked upwards
              if (_dragDistance < -15.0 || velocity < -120.0) {
                _openQueue();
              }
            },
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(20, 8, 16, 12 + bottomInset),
              decoration: BoxDecoration(
                color: const Color(0xFF141418),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(22)),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.12),
                    width: 1,
                  ),
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 16,
                    offset: Offset(0, -3),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.28),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Row(
                    children: [
                      Icon(
                        Icons.queue_music_rounded,
                        size: 18,
                        color: widget.accent,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'UP NEXT',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                          color: widget.accent,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: widget.accent.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${queue.length}',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: widget.accent,
                          ),
                        ),
                      ),
                      if (nextSong != null) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            nextSong.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.65),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ] else ...[
                        const Spacer(),
                      ],
                      Icon(
                        Icons.keyboard_arrow_up_rounded,
                        size: 22,
                        color: Colors.white.withValues(alpha: 0.65),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}