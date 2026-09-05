import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../services/player_service.dart';
import 'rhythm_pulse.dart';
import 'visual_synthesizer_bar.dart';

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
    final stateLabel = (player.isLoadingTrack && !player.playing)
        ? 'Buffering track...'
        : [
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
            Stack(
              alignment: Alignment.center,
              children: [
                RhythmPulseBuilder(
                  player: player,
                  child: RepaintBoundary(
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.55),
                            blurRadius: 24.0,
                            spreadRadius: 2.0,
                          ),
                        ],
                      ),
                    ),
                  ),
                  builder: (context, aura, cachedGlow) {
                    return Opacity(
                      opacity: (aura * 0.90).clamp(0.0, 1.0),
                      child: cachedGlow,
                    );
                  },
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 72,
                  icon: (player.isLoadingTrack && !player.playing)
                      ? Center(
                          child: SizedBox(
                            width: 52,
                            height: 52,
                            child: CircularProgressIndicator(
                              strokeWidth: 3.5,
                              color: scheme.primary,
                            ),
                          ),
                        )
                      : Icon(
                          player.playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          size: 72,
                          color: scheme.primary,
                        ),
                  onPressed: () => controller.togglePlayback(),
                ),
              ],
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
            color: (player.isLoadingTrack && !player.playing) || loopActive || player.shuffle
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
  final ValueNotifier<double?> _dragNotifier = ValueNotifier(null);
  bool _showRemaining = true;

  @override
  void dispose() {
    _dragNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final totalMs = widget.duration.inMilliseconds.toDouble();
    final useSynthesizer = context.select<AppController?, bool>(
      (c) => c?.identity.synthesizerBar ?? false,
    );

    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      initialData: widget.player.position ?? Duration.zero,
      builder: (context, snapshot) {
        final pos = snapshot.data ?? Duration.zero;
        final maxMs = totalMs > 0 ? totalMs : 1.0;
        final baseMs = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);

        // RepaintBoundary isolates the ticking slider and time-row repaints
        // from the album art and background canvas layers.
        return RepaintBoundary(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (useSynthesizer)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: VisualSynthesizerBar(
                    player: widget.player,
                    currentPosition: pos,
                    totalDuration: widget.duration,
                    onSeek: (duration) => widget.player.seek(duration),
                    onDragUpdate: (ms) => _dragNotifier.value = ms,
                    onDragEnd: () => _dragNotifier.value = null,
                  ),
                )
              else
                ValueListenableBuilder<double?>(
                  valueListenable: _dragNotifier,
                  builder: (context, dragMs, _) {
                    final currentVal = (dragMs ?? baseMs).clamp(0.0, maxMs);
                    return SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: dragMs != null ? 6.0 : 4.0,
                        trackShape: const RoundedRectSliderTrackShape(),
                        activeTrackColor: colorScheme.primary,
                        inactiveTrackColor: colorScheme.onSurface.withValues(alpha: 0.12),
                        thumbColor: colorScheme.primary,
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius: dragMs != null ? 7.0 : 5.0,
                          elevation: dragMs != null ? 3.0 : 1.0,
                        ),
                        overlayColor: colorScheme.primary.withValues(
                          alpha: 0.12,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14.0,
                        ),
                      ),
                      child: Slider(
                        value: currentVal,
                        max: maxMs,
                        onChangeStart: (ms) => _dragNotifier.value = ms,
                        onChanged: (ms) => _dragNotifier.value = ms,
                        onChangeEnd: (ms) {
                          widget.player.seek(Duration(milliseconds: ms.round()));
                          _dragNotifier.value = null;
                        },
                      ),
                    );
                  },
                ),
                  ValueListenableBuilder<double?>(
                    valueListenable: _dragNotifier,
                    builder: (context, dragMs, _) {
                      final effectiveMs = (dragMs ?? pos.inMilliseconds.toDouble()).clamp(0.0, maxMs);
                      final currentDuration = Duration(milliseconds: effectiveMs.round());
                      final remainingDuration = widget.duration > currentDuration
                          ? widget.duration - currentDuration
                          : Duration.zero;

                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _fmt(currentDuration),
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontFeatures: const [FontFeature.tabularFigures()],
                                color: dragMs != null ? colorScheme.primary : colorScheme.onSurfaceVariant,
                                fontWeight: dragMs != null ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                            GestureDetector(
                              onTap: () {
                                context.read<AppController?>()?.updateSynthesizerBar(!useSynthesizer);
                              },
                              behavior: HitTestBehavior.opaque,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        useSynthesizer ? Icons.graphic_eq_rounded : Icons.linear_scale_rounded,
                                        size: 13,
                                        color: useSynthesizer ? colorScheme.primary : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        useSynthesizer ? 'Visualizer' : 'Standard',
                                        style: theme.textTheme.labelSmall?.copyWith(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          color: useSynthesizer ? colorScheme.primary : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                                        ),
                                      ),
                                    ],
                                  ),
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
                                  color: dragMs != null ? colorScheme.primary : colorScheme.onSurfaceVariant,
                                  fontWeight: dragMs != null ? FontWeight.w700 : FontWeight.w500,
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4.0,
            trackShape: const RoundedRectSliderTrackShape(),
            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: 6.0,
              elevation: 1.0,
            ),
            overlayShape: const RoundSliderOverlayShape(
              overlayRadius: 12.0,
            ),
            activeTrackColor: scheme.primary,
            inactiveTrackColor: scheme.outlineVariant.withValues(alpha: 0.35),
            thumbColor: scheme.primary,
          ),
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
      ),
    );
  }
}
