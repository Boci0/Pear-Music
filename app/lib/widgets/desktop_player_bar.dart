import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../screens/player_screen.dart';
import '../services/artwork_palette.dart';
import '../services/player_service.dart';

/// Full-width 3-section desktop player bar (Spotify / Apple Music style).
class DesktopPlayerBar extends StatefulWidget {
  const DesktopPlayerBar({super.key});

  @override
  State<DesktopPlayerBar> createState() => _DesktopPlayerBarState();
}

class _DesktopPlayerBarState extends State<DesktopPlayerBar> {
  double? _dragPositionSeconds;
  double? _dragVolume;
  double _preMuteVolume = 1.0;

  String _formatDuration(Duration? d) {
    if (d == null || d.inSeconds <= 0) return '0:00';
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final song = player.currentSong;
    if (song == null) return const SizedBox.shrink();

    final controller = context.read<AppController>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isFav = controller.isFavorite(song.id);

    final duration = player.duration ?? Duration.zero;
    final position = player.position ?? Duration.zero;
    final maxSec = duration.inMilliseconds > 0
        ? duration.inMilliseconds / 1000.0
        : 1.0;
    final curSec = _dragPositionSeconds ??
        (position.inMilliseconds / 1000.0).clamp(0.0, maxSec);

    final accent = ArtworkPalette.dominantSync(song);
    final control = ArtworkPalette.controlAccent(accent);
    final barColor = Color.lerp(
          scheme.surfaceContainerHigh,
          ArtworkPalette.wash(accent, lightness: 0.12),
          0.40,
        ) ??
        scheme.surfaceContainerHigh;

    return Container(
      height: 84,
          decoration: BoxDecoration(
            color: barColor,
            border: Border(
              top: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.35),
                width: 1,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              // ---------------- Left: Track Info & Favorite ----------------
              SizedBox(
                width: 260,
                child: Row(
                  children: [
                    InkWell(
                      onTap: () => _openPlayerScreen(context),
                      borderRadius: BorderRadius.circular(8),
                      child: _DesktopThumb(song: song),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InkWell(
                            onTap: () => _openPlayerScreen(context),
                            child: Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            player.queueTitle ?? 'Pear Music Library',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: isFav
                          ? 'Remove from Favorites'
                          : 'Add to Favorites',
                      icon: Icon(
                        isFav ? Icons.favorite : Icons.favorite_border,
                        size: 20,
                        color: isFav ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                      onPressed: () => controller.toggleFavorite(song.id),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 16),

              // ---------------- Center: Transport & Scrubber ----------------
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Transport Buttons
                    SizedBox(
                      height: 38,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            tooltip:
                                'Shuffle (${player.shuffle ? "on" : "off"})',
                            icon: Icon(
                              Icons.shuffle,
                              size: 18,
                              color: player.shuffle
                                  ? control
                                  : scheme.onSurfaceVariant
                                      .withValues(alpha: 0.6),
                            ),
                            onPressed: () => controller.toggleShuffle(),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            tooltip: 'Previous',
                            icon: Icon(Icons.skip_previous,
                                size: 22, color: control),
                            onPressed: () => controller.previousTrack(),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            tooltip: player.playing ? 'Pause' : 'Play',
                            icon: Icon(
                              player.playing
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled,
                              size: 36,
                              color: player.isLoadingTrack
                                  ? control.withValues(alpha: 0.38)
                                  : control,
                            ),
                            onPressed: player.isLoadingTrack ? null : () => controller.togglePlayback(),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            tooltip: 'Next',
                            icon:
                                Icon(Icons.skip_next, size: 22, color: control),
                            onPressed: () => controller.nextTrack(),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            tooltip: _loopTooltip(player.loopMode),
                            icon: Icon(
                              _loopIcon(player.loopMode),
                              size: 18,
                              color: player.loopMode != LoopSetting.off
                                  ? control
                                  : scheme.onSurfaceVariant
                                      .withValues(alpha: 0.6),
                            ),
                            onPressed: () => controller.toggleLoop(),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 2),

                    // Progress Scrubber (StreamBuilder for zero CPU overhead)
                    StreamBuilder<Duration>(
                      stream: player.positionStream,
                      initialData: player.position ?? Duration.zero,
                      builder: (context, posSnap) {
                        final position = posSnap.data ?? Duration.zero;
                        final curSec = _dragPositionSeconds ??
                            (position.inMilliseconds / 1000.0).clamp(0.0, maxSec);
                        return SizedBox(
                          height: 24,
                          child: Row(
                            children: [
                              SizedBox(
                                width: 38,
                                child: Text(
                                  _formatDuration(
                                    _dragPositionSeconds != null
                                        ? Duration(
                                            milliseconds:
                                                (_dragPositionSeconds! * 1000)
                                                    .toInt(),
                                          )
                                        : position,
                                  ),
                                  textAlign: TextAlign.right,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 3.5,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 5.5,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 10,
                                    ),
                                    activeTrackColor: control,
                                    inactiveTrackColor: scheme.outlineVariant
                                        .withValues(alpha: 0.35),
                                    thumbColor: control,
                                  ),
                                  child: Slider(
                                    value: curSec.clamp(0.0, maxSec),
                                    min: 0.0,
                                    max: maxSec > 0 ? maxSec : 1.0,
                                    onChanged: (v) {
                                      setState(() => _dragPositionSeconds = v);
                                    },
                                    onChangeEnd: (v) {
                                      setState(() => _dragPositionSeconds = null);
                                      player.seek(
                                        Duration(milliseconds: (v * 1000).toInt()),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 38,
                                child: Text(
                                  _formatDuration(duration),
                                  textAlign: TextAlign.left,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 16),

              // ---------------- Right: Volume & Full Player ----------------
              SizedBox(
                width: 240,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: 'Now Playing Fullscreen',
                      icon: const Icon(Icons.open_in_full, size: 18),
                      onPressed: () => _openPlayerScreen(context),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: player.volume == 0 ? 'Unmute' : 'Mute',
                      icon: Icon(
                        player.volume == 0
                            ? Icons.volume_off
                            : (player.volume < 0.5
                                ? Icons.volume_down
                                : Icons.volume_up),
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                      onPressed: () {
                        if (player.volume > 0) {
                          _preMuteVolume = player.volume;
                          player.setVolume(0.0);
                        } else {
                          player.setVolume(
                              _preMuteVolume > 0 ? _preMuteVolume : 1.0);
                        }
                      },
                    ),
                    SizedBox(
                      width: 110,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3.5,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 5.5,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 10,
                          ),
                          activeTrackColor: control,
                          inactiveTrackColor:
                              scheme.outlineVariant.withValues(alpha: 0.35),
                          thumbColor: control,
                        ),
                        child: Slider(
                          value: (_dragVolume ?? player.volume).clamp(0.0, 1.0),
                          min: 0.0,
                          max: 1.0,
                          onChanged: (val) {
                            setState(() => _dragVolume = val);
                            player.setVolume(val);
                          },
                          onChangeEnd: (_) {
                            setState(() => _dragVolume = null);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
  }

  void _openPlayerScreen(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 150),
        reverseTransitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (context, animation, secondaryAnimation) =>
            const PlayerScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  String _loopTooltip(LoopSetting loop) {
    switch (loop) {
      case LoopSetting.off:
        return 'Repeat off';
      case LoopSetting.all:
        return 'Repeat all';
      case LoopSetting.one:
        return 'Repeat one';
    }
  }

  IconData _loopIcon(LoopSetting loop) {
    switch (loop) {
      case LoopSetting.off:
      case LoopSetting.all:
        return Icons.repeat;
      case LoopSetting.one:
        return Icons.repeat_one;
    }
  }
}

class _DesktopThumb extends StatelessWidget {
  final Song song;
  const _DesktopThumb({required this.song});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artwork = song.artwork;
    final placeholder = Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
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
        size: 22,
      ),
    );
    if (artwork == null || artwork.isEmpty) return placeholder;
    if (artwork.startsWith('http')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          artwork,
          width: 48,
          height: 48,
          cacheWidth: 96,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => placeholder,
        ),
      );
    }
    final bytes = ArtworkPalette.bytes(song);
    if (bytes == null || bytes.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(
        bytes,
        width: 48,
        height: 48,
        cacheWidth: 96,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}
