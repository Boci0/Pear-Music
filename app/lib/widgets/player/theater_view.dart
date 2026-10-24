import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../services/artwork_palette.dart';
import '../../services/player_service.dart';
import '../../services/video_service.dart';
import '../tactile_button.dart';
import 'player_artwork.dart';
import 'player_controls.dart';
import 'player_stage_body.dart';
import 'player_video_view.dart';

/// Theater mode (wide windows): the video or the
/// cover fills the centre, the synced lyrics stand in a column on the right
/// (L shows or hides them), and the controls span the bottom edge. Escape
/// or the exit button calls [onClose].
class TheaterView extends StatefulWidget {
  const TheaterView({super.key, required this.onClose});

  final VoidCallback onClose;

  static const double lyricsWidth = 380;

  @override
  State<TheaterView> createState() => _TheaterViewState();
}

class _TheaterViewState extends State<TheaterView> {
  bool _lyrics = true;

  void _toggleLyrics() => setState(() => _lyrics = !_lyrics);

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final controller = context.read<AppController>();
    final song = player.currentSong;
    // L here shows or hides the lyrics; elsewhere it seeks forward, which
    // Ctrl+Alt+L still does in here.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyL): _toggleLyrics,
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Focus(
        autofocus: true,
        child: song == null
            ? Center(
                child: TextButton(
                  onPressed: widget.onClose,
                  child: const Text('NOTHING PLAYING'),
                ),
              )
            : _buildPlaying(context, player, controller),
      ),
    );
  }

  Widget _buildPlaying(
    BuildContext context,
    PlayerService player,
    AppController controller,
  ) {
    final song = player.currentSong!;
    final accent = ArtworkPalette.dominantSync(song);
    final showVideo = context.watch<VideoService?>()?.showingFor(song) ?? false;
    final muted = Colors.white.withValues(alpha: 0.55);
    return Column(
      key: const ValueKey('theater_view'),
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 20, 32, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 320),
                          child: PlayerViewTabs(
                            song: song,
                            accent: accent,
                            lyrics: false,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, c) => Center(
                            child: showVideo
                                ? PlayerVideoView(
                                    accent: accent,
                                    maxWidth: c.maxWidth,
                                    maxHeight: c.maxHeight,
                                  )
                                : PlayerArtworkHero(
                                    song: song,
                                    size: math.max(
                                      80,
                                      math.min(c.maxWidth, c.maxHeight),
                                    ),
                                    artwork: ArtworkPalette.cachedBytes(song),
                                    accent: accent,
                                    viewButtons: false,
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: StageSongInfo(song: song, accent: accent),
                          ),
                          const SizedBox(width: 12),
                          StageToolIcon(
                            key: const ValueKey('theater_lyrics'),
                            icon: Icons.lyrics_outlined,
                            tooltip: _lyrics
                                ? 'Hide lyrics (L)'
                                : 'Show lyrics (L)',
                            active: _lyrics,
                            onTap: _toggleLyrics,
                          ),
                          const SizedBox(width: 4),
                          TactileIconButton(
                            key: const ValueKey('theater_close'),
                            tooltip: 'Leave Theater (Esc)',
                            icon: Icon(
                              Icons.close_fullscreen_rounded,
                              color: muted,
                            ),
                            onPressed: widget.onClose,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (_lyrics)
                SizedBox(
                  width: TheaterView.lyricsWidth,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 20, 24, 16),
                    child: StageLyricsPanel(
                      key: ValueKey('theater_lyrics_${song.id}'),
                      song: song,
                      player: player,
                      accent: accent,
                    ),
                  ),
                ),
            ],
          ),
        ),
        // The controls along the bottom edge.
        Container(
          padding: const EdgeInsets.fromLTRB(16, 6, 24, 6),
          decoration: BoxDecoration(
            color: const Color(0xFF111114),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 300,
                child: PlayerTransport(
                  player: player,
                  controller: controller,
                  accent: accent,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: PlayerSeekBar(
                  player: player,
                  duration: player.duration ?? Duration.zero,
                  accent: accent,
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 240,
                // Queue leaves Theater: the panel's Up next is the queue.
                child: StageToolsRow(
                  player: player,
                  controller: controller,
                  song: song,
                  onOpenQueue: widget.onClose,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 150,
                child: PlayerVolumeSlider(
                  accent: ArtworkPalette.controlAccent(accent),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
