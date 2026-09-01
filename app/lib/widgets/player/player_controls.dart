import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../services/player_service.dart';

/// Previous / play-pause / next transport buttons, flanked by shuffle and
/// repeat controls.
class PlayerTransport extends StatelessWidget {
  final PlayerService player;
  final AppController controller;
  const PlayerTransport({
    super.key,
    required this.player,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loopIcon = switch (player.loopMode) {
      LoopSetting.one => Icons.repeat_one,
      _ => Icons.repeat,
    };
    final loopActive = player.loopMode != LoopSetting.off;
    final loopLabel = switch (player.loopMode) {
      LoopSetting.one => 'Repeat one (this song)',
      LoopSetting.all => 'Repeat all (album)',
      LoopSetting.off => 'No repeat',
    };
    final stateLabel = [
      if (player.shuffle) 'Shuffle on',
      loopLabel,
    ].join(' · ');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              iconSize: 32,
              icon: Icon(
                Icons.shuffle,
                color: player.shuffle
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
              tooltip: player.shuffle ? 'Shuffle on' : 'Shuffle',
              onPressed: controller.toggleShuffle,
            ),
            IconButton(
              iconSize: 44,
              icon: const Icon(Icons.skip_previous_rounded),
              onPressed: () => controller.previousTrack(),
            ),
            IconButton(
              iconSize: 72,
              icon: Icon(
                player.playing
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled,
                color: (player.isLoadingTrack && !player.playing)
                    ? scheme.primary.withValues(alpha: 0.38)
                    : scheme.primary,
              ),
              onPressed: () => controller.togglePlayback(),
            ),
            IconButton(
              iconSize: 44,
              icon: const Icon(Icons.skip_next_rounded),
              onPressed: () => controller.nextTrack(),
            ),
            IconButton(
              iconSize: 32,
              icon: Icon(
                loopIcon,
                color: loopActive ? scheme.primary : scheme.onSurfaceVariant,
              ),
              tooltip: loopLabel,
              onPressed: controller.toggleLoop,
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          stateLabel,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: loopActive || player.shuffle
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Seek bar + current/total time. Subscribes to the throttled position stream
/// (250 ms) so a position tick only rebuilds this small subtree instead of the
/// whole player screen.
class PlayerSeekBar extends StatefulWidget {
  final PlayerService player;
  final Duration duration;
  const PlayerSeekBar({
    super.key,
    required this.player,
    required this.duration,
  });

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar> {
  /// Non-null while the user is dragging: the thumb position in ms.
  double? _dragMs;
  bool _showRemaining = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final totalMs = widget.duration.inMilliseconds.toDouble();

    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      initialData: widget.player.position ?? Duration.zero,
      builder: (context, snapshot) {
        final pos = snapshot.data ?? Duration.zero;
        final currentMs = _dragMs ?? pos.inMilliseconds.toDouble();
        final maxMs = totalMs > 0 ? totalMs : 1.0;
        final clampedValue = currentMs.clamp(0.0, maxMs);
        final currentDuration = Duration(milliseconds: clampedValue.round());
        final remainingDuration = widget.duration > currentDuration
            ? widget.duration - currentDuration
            : Duration.zero;

        // RepaintBoundary isolates the ticking slider and time-row repaints
        // from the album art and background canvas layers.
        return RepaintBoundary(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: _dragMs != null ? 6.0 : 4.0,
                  trackShape: const RoundedRectSliderTrackShape(),
                  activeTrackColor: colorScheme.primary,
                  inactiveTrackColor: colorScheme.onSurface.withValues(alpha: 0.12),
                  thumbColor: colorScheme.primary,
                  thumbShape: RoundSliderThumbShape(
                    enabledThumbRadius: _dragMs != null ? 8.0 : 5.0,
                    elevation: _dragMs != null ? 4.0 : 1.0,
                  ),
                  overlayColor: colorScheme.primary.withValues(alpha: 0.15),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
                ),
                child: Slider(
                  value: clampedValue,
                  max: maxMs,
                  onChangeStart: (ms) => setState(() => _dragMs = ms),
                  onChanged: (ms) => setState(() => _dragMs = ms),
                  onChangeEnd: (ms) {
                    widget.player.seek(Duration(milliseconds: ms.round()));
                    setState(() => _dragMs = null);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _fmt(currentDuration),
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _showRemaining = !_showRemaining),
                      behavior: HitTestBehavior.opaque,
                      child: Text(
                        _showRemaining
                            ? '-${_fmt(remainingDuration)}'
                            : _fmt(widget.duration),
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Volume icons + slider.
class PlayerVolumeRow extends StatelessWidget {
  const PlayerVolumeRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.volume_down,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const Expanded(child: PlayerVolumeSlider()),
        Icon(
          Icons.volume_up,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ],
    );
  }
}

/// Volume slider with real-time volume adjustment and mouse scroll wheel
/// control.
class PlayerVolumeSlider extends StatefulWidget {
  const PlayerVolumeSlider({super.key});

  @override
  State<PlayerVolumeSlider> createState() => _PlayerVolumeSliderState();
}

class _PlayerVolumeSliderState extends State<PlayerVolumeSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final value = _dragValue ?? player.volume.clamp(0.0, 1.0);
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
          final next = (player.volume + delta).clamp(0.0, 1.0);
          player.setVolume(next);
          setState(() => _dragValue = next);
        }
      },
      // RepaintBoundary keeps drag-tick repaints on the slider layer.
      child: RepaintBoundary(
        child: Slider(
          value: value,
          onChangeStart: (_) =>
              setState(() => _dragValue = player.volume.clamp(0.0, 1.0)),
          onChanged: (v) {
            setState(() => _dragValue = v);
            player.setVolume(v);
          },
          onChangeEnd: (_) => setState(() => _dragValue = null),
        ),
      ),
    );
  }
}
