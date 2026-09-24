import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../screens/player_screen.dart';
import '../services/artwork_palette.dart';
import '../services/artwork_service.dart';
import '../services/player_service.dart';
import 'pear_page_route.dart';
import 'player/player_controls.dart';
import 'tactile_button.dart';

/// Old-school desktop "Now Playing" pane: big artwork, title, transport
/// controls and a progress line, pinned to the right of the wide shell.
class NowPlayingPanel extends StatelessWidget {
  const NowPlayingPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final song = player.currentSong;
    final theme = Theme.of(context);

    return Container(
      key: const ValueKey('now_playing_panel'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF151518),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: song == null
          ? _buildEmptyState(theme)
          : _buildPlayingState(context, player, song, theme),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.music_note_rounded,
              size: 42,
              color: Colors.white.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 12),
            Text(
              'Nothing playing',
              style: theme.textTheme.titleSmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Pick a song to start listening',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayingState(
    BuildContext context,
    PlayerService player,
    Song song,
    ThemeData theme,
  ) {
    final controller = context.read<AppController>();
    final accent = ArtworkPalette.dominantSync(song);
    final control = ArtworkPalette.controlAccent(accent);
    final meta = song.sourceDeviceId == 'stream'
        ? 'Stream · Pear Radio'
        : song.sourceDeviceId != null
        ? 'Shared · ${song.sizeLabel}'
        : 'Local · ${song.sizeLabel}';

    return InkWell(
      onTap: () {
        TactileFeedback.click();
        Navigator.of(
          context,
        ).push(PearPageRoute(builder: (_) => const PlayerScreen()));
      },
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final artSize = math
                .min(constraints.maxWidth, constraints.maxHeight - 290)
                .clamp(120.0, constraints.maxWidth);
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: artSize,
                  height: artSize,
                  child: _Artwork(song: song),
                ),
                const SizedBox(height: 16),
                Text(
                  song.title,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12.5,
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TactileIconButton(
                      icon: Icon(Icons.skip_previous, color: control),
                      iconSize: 28,
                      tooltip: 'Previous',
                      onPressed: () => controller.previousTrack(),
                    ),
                    const SizedBox(width: 4),
                    TactileBounce(
                      onTap: () => controller.togglePlayback(),
                      scaleDown: 0.88,
                      tooltip: player.playbackError != null
                          ? 'Retry'
                          : (player.playing ? 'Pause' : 'Play'),
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: Center(
                          child: player.isBuffering
                              ? SizedBox(
                                  width: 34,
                                  height: 34,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: control,
                                  ),
                                )
                              : Icon(
                                  player.playing
                                      ? Icons.pause_circle_filled
                                      : Icons.play_circle_filled,
                                  size: 52,
                                  color: control,
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    TactileIconButton(
                      icon: Icon(Icons.skip_next, color: control),
                      iconSize: 28,
                      tooltip: 'Next',
                      onPressed: () => controller.nextTrack(),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _ProgressLine(player: player, color: control, theme: theme),
                const SizedBox(height: 4),
                PlayerVolumeRow(accent: control),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ProgressLine extends StatelessWidget {
  final PlayerService player;
  final Color color;
  final ThemeData theme;

  const _ProgressLine({
    required this.player,
    required this.color,
    required this.theme,
  });

  String _formatTime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
    return '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final timeStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 10.5,
      color: Colors.white.withValues(alpha: 0.5),
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      initialData: player.duration,
      builder: (context, durSnapshot) {
        final total = durSnapshot.data ?? player.duration ?? Duration.zero;
        final totalMs = total.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          initialData: player.position ?? Duration.zero,
          builder: (context, posSnapshot) {
            final pos = posSnapshot.data ?? player.position ?? Duration.zero;
            final fraction = totalMs <= 0
                ? 0.0
                : (pos.inMilliseconds / totalMs).clamp(0.0, 1.0);
            return Row(
              children: [
                Text(_formatTime(pos), style: timeStyle),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      height: 4,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ColoredBox(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                          FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: fraction,
                            child: ColoredBox(color: color),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(_formatTime(total), style: timeStyle),
              ],
            );
          },
        );
      },
    );
  }
}

class _Artwork extends StatelessWidget {
  final Song song;
  const _Artwork({required this.song});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primaryContainer,
            theme.colorScheme.primary.withValues(alpha: 0.6),
          ],
        ),
      ),
      child: Icon(
        Icons.music_note_rounded,
        color: theme.colorScheme.onPrimaryContainer,
        size: 56,
      ),
    );

    final artwork = song.artwork;
    Widget image;
    if (artwork == null || artwork.isEmpty) {
      image = placeholder;
    } else if (artwork.startsWith('http')) {
      image = Image.network(
        ArtworkService.optimizeArtworkUrl(artwork),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => placeholder,
      );
    } else {
      final cached = ArtworkPalette.cachedBytes(song);
      image = FutureBuilder<Uint8List?>(
        initialData: cached,
        future: ArtworkPalette.bytesAsync(song),
        builder: (context, snapshot) {
          final bytes = snapshot.data ?? cached;
          if (bytes == null || bytes.isEmpty) return placeholder;
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
          );
        },
      );
    }

    return ClipRRect(borderRadius: BorderRadius.circular(16), child: image);
  }
}
