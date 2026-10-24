import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../screens/player_screen.dart';
import '../services/artwork_palette.dart';
import '../services/artwork_service.dart';
import '../services/player_service.dart';
import '../theme/glass.dart';
import 'live_badge.dart';
import 'pear_page_route.dart';
import 'player/mini_visualizer.dart';
import 'tactile_button.dart';

/// Compact now-playing bar shown above the navigation bar.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, this.embedded = false});

  /// Drawn inside the phone dock: no margins and no glass of its own.
  final bool embedded;


  @override
  Widget build(BuildContext context) {
    // Watch only the player so this bar rebuilds on playback state changes
    // (rare) and not on library/connection/transfer updates.
    final player = context.watch<PlayerService>();
    final song = player.currentSong;
    if (song == null) return const SizedBox.shrink();
    final controller = context.read<AppController>();
    final theme = Theme.of(context);

    // Carry the current song's artwork colour into the mini player too, so
    // the colour follows the music outside the full player.
    final accent = ArtworkPalette.dominantSync(song);
    final control = ArtworkPalette.controlAccent(accent);

    final screenWidth = MediaQuery.sizeOf(context).width;
    final hMargin = screenWidth < 380 ? 10.0 : 16.0;
    // Soft bars behind the mini player are their own opt-in setting, on top
    // of the visualizer itself, and never while Reduced Effects is on (it
    // exists to cut repainting).
    final showVisualizer = context.select<AppController?, bool>(
      (c) =>
          (c?.identity.synthesizerBar ?? false) &&
          (c?.identity.miniVisualizer ?? false) &&
          !(c?.identity.reducedEffects ?? false),
    );

    return Padding(
      padding: embedded
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(hMargin, 0, hMargin, 6),
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          final vx = details.primaryVelocity ?? 0;
          if (vx < -200) {
            controller.nextTrack();
          } else if (vx > 200) {
            controller.previousTrack();
          }
        },
        onVerticalDragEnd: (details) {
          final vy = details.primaryVelocity ?? 0;
          if (vy < -200) {
            _openPlayer(context);
          }
        },
        child: PearGlass(
          surface: !embedded,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              mouseCursor: WidgetStateMouseCursor.clickable,
              onTap: () => _openPlayer(context),
              child: Stack(
                children: [
                  if (showVisualizer)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: MiniVisualizer(player: player, color: control),
                      ),
                    ),
                  Padding(
                    padding: embedded
                        ? const EdgeInsets.fromLTRB(
                            PearGlassTokens.dockInset,
                            PearGlassTokens.dockInset,
                            PearGlassTokens.dockInset - 4,
                            PearGlassTokens.dockInset,
                          )
                        : const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                    child: Row(
                      children: [
                        PlayerBarThumb(
                          song: song,
                          radius: PearGlassTokens.r(
                            embedded ? PearGlassTokens.dockInnerRadius : 8,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.1,
                                ),
                              ),
                              if (player.playbackError != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  player.playbackError!.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.error,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ] else if (player.isLive &&
                                  !player.isBuffering) ...[
                                const SizedBox(height: 3),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const LiveBadge(),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: LiveLabel(
                                        compact: true,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                          color: theme
                                              .colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ] else if (player.isLoadingRecommendations ||
                                  player.isBuffering) ...[
                                const SizedBox(height: 2),
                                Text(
                                  player.isLoadingRecommendations
                                      ? 'Finding next tracks...'
                                      : 'Buffering track...',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ] else ...[
                                // Always a status line, like a read-out under
                                // a module's name.
                                const SizedBox(height: 2),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      player.playing ? 'PLAYING' : 'PAUSED',
                                      maxLines: 1,
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.4,
                                        color: control,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    // The pips are the song's progress:
                                    // they light up one by one as it plays.
                                    if (!player.isLive)
                                      Flexible(
                                        child: _ProgressPips(
                                          player: player,
                                          color: control,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        TactileIconButton(
                          icon: Icon(Icons.skip_previous, color: control),
                          iconSize: 24,
                          tooltip: 'Previous',
                          onPressed: () => controller.previousTrack(),
                        ),
                        TactileBounce(
                          onTap: () => controller.togglePlayback(),
                          scaleDown: 0.88,
                          tooltip: player.playbackError != null
                              ? 'Retry'
                              : (player.playing ? 'Pause' : 'Play'),
                          child: SizedBox(
                            width: 38,
                            height: 38,
                            child: Center(
                              child: player.isBuffering
                                  ? SizedBox(
                                      width: 26,
                                      height: 26,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        color: control,
                                      ),
                                    )
                                  : Icon(
                                      player.playing
                                          ? Icons.pause_circle_filled
                                          : Icons.play_circle_filled,
                                      size: 38,
                                      color: control,
                                    ),
                            ),
                          ),
                        ),
                        TactileIconButton(
                          icon: Icon(Icons.skip_next, color: control),
                          iconSize: 24,
                          tooltip: 'Next',
                          onPressed: () => controller.nextTrack(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
      ),
    ),
  ),
);
  }

  void _openPlayer(BuildContext context) => openPlayer(context);

  /// Opens the full-screen player, as a tap on the bar does.
  static void openPlayer(BuildContext context) {
    TactileFeedback.click();
    Navigator.of(context).push(
      PearPageRoute(
        builder: (_) => const PlayerScreen(),
      ),
    );
  }
}

/// 40x40 artwork thumb for the now-playing bar (and the landscape rail).
class PlayerBarThumb extends StatelessWidget {
  final Song song;
  final double radius;
  const PlayerBarThumb({super.key, required this.song, this.radius = 8});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artwork = song.artwork;
    final placeholder = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(PearGlassTokens.r(radius)),
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primaryContainer,
            theme.colorScheme.primary.withValues(alpha: 0.6),
          ],
        ),
      ),
      child: Icon(
        Icons.music_note,
        color: theme.colorScheme.onPrimaryContainer,
        size: 20,
      ),
    );

    Widget imageWidget;
    if (artwork == null || artwork.isEmpty) {
      imageWidget = placeholder;
    } else if (artwork.startsWith('http')) {
      final optimized = ArtworkService.optimizeArtworkUrl(artwork);
      imageWidget = ClipRRect(
        borderRadius: BorderRadius.circular(PearGlassTokens.r(radius)),
        child: Image.network(
          optimized,
          width: 40,
          height: 40,
          cacheWidth: 100,
          
          fit: BoxFit.cover,
          alignment: Alignment.center,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => Image.network(
            artwork,
            width: 40,
            height: 40,
            cacheWidth: 100,
            
            fit: BoxFit.cover,
            alignment: Alignment.center,
            errorBuilder: (_, _, _) => placeholder,
          ),
        ),
      );
    } else {
      final bytes = ArtworkPalette.bytes(song);
      if (bytes == null || bytes.isEmpty) {
        imageWidget = placeholder;
      } else {
        imageWidget = ClipRRect(
          borderRadius: BorderRadius.circular(PearGlassTokens.r(radius)),
          child: Image.memory(
            bytes,
            width: 40,
            height: 40,
            cacheWidth: 96,
            
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
          ),
        );
      }
    }

    return imageWidget;
  }
}

/// Progress as a row of pips after the PLAYING / PAUSED label: each lights in
/// turn as the song plays, the current one partly; dimmer while paused.
class _ProgressPips extends StatelessWidget {
  const _ProgressPips({required this.player, required this.color});

  final PlayerService player;
  final Color color;

  static const int most = 8;

  @override
  Widget build(BuildContext context) {
    // Fewer pips when the bar is narrow (a phone held sideways).
    return LayoutBuilder(
      builder: (context, box) {
        final count = box.maxWidth.isFinite
            ? (box.maxWidth / 5).floor().clamp(0, most)
            : most;
        return _pips(count);
      },
    );
  }

  Widget _pips(int count) {
    return RepaintBoundary(
      child: StreamBuilder<Duration>(
        stream: player.uiPositionStream,
        initialData: player.position ?? Duration.zero,
        builder: (context, snap) {
          final total = (player.duration ?? Duration.zero).inMilliseconds;
          final pos = (snap.data ?? Duration.zero).inMilliseconds;
          final lit = total <= 0 ? 0.0 : (pos / total).clamp(0.0, 1.0) * count;
          final strength = player.playing ? 1.0 : 0.6;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < count; i++)
                Container(
                  width: 3,
                  height: 8,
                  margin: const EdgeInsets.only(right: 2),
                  color: Color.lerp(
                    Colors.white.withValues(alpha: 0.14),
                    color.withValues(alpha: strength),
                    (lit - i).clamp(0.0, 1.0),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
