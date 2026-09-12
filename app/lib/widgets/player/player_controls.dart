import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../services/player_service.dart';
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
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
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
        final stateLabel = player.isLoadingRecommendations
            ? 'Finding next tracks...'
            : player.isBuffering
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
                _PlayPauseButton(
                  player: player,
                  controller: controller,
                  scheme: scheme,
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
                color: player.isBuffering || loopActive || player.shuffle
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PlayPauseButton extends StatefulWidget {
  final PlayerService player;
  final AppController controller;
  final ColorScheme scheme;

  const _PlayPauseButton({
    required this.player,
    required this.controller,
    required this.scheme,
  });

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    final player = widget.player;
    final isBuffering = player.isBuffering;
    final isPlaying = player.playing;

    final bgColor = scheme.primary.withValues(
      alpha: _isPressed
          ? 0.35
          : _isHovered
              ? 0.28
              : 0.22,
    );
    final borderColor = scheme.primary.withValues(
      alpha: _isHovered ? 0.55 : 0.38,
    );

    return SizedBox(
      width: 72,
      height: 72,
      child: Center(
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTapDown: (_) => setState(() => _isPressed = true),
            onTapUp: (_) {
              setState(() => _isPressed = false);
              widget.controller.togglePlayback();
            },
            onTapCancel: () => setState(() => _isPressed = false),
            behavior: HitTestBehavior.opaque,
            child: Tooltip(
              message: isBuffering
                  ? 'Buffering...'
                  : isPlaying
                      ? 'Pause'
                      : 'Play',
              child: AnimatedScale(
                scale: _isPressed ? 0.90 : (_isHovered ? 1.05 : 1.0),
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: bgColor,
                    border: Border.all(
                      color: borderColor,
                      width: 1.2,
                    ),
                  ),
                  child: Center(
                    child: isBuffering
                        ? SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 3.0,
                              color: scheme.primary,
                            ),
                          )
                        : Padding(
                            padding: EdgeInsets.only(left: isPlaying ? 0.0 : 2.5),
                            child: Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: isPlaying ? 34 : 38,
                              color: scheme.primary,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
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
                    onDragUpdate: (ms) {
                      _dragNotifier.value = ms;
                      widget.player.setScrubbingPosition(Duration(milliseconds: ms.round()));
                    },
                    onDragEnd: () {
                      _dragNotifier.value = null;
                      widget.player.setScrubbingPosition(null);
                    },
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
                        onChangeStart: (ms) {
                          _dragNotifier.value = ms;
                          widget.player.setScrubbingPosition(Duration(milliseconds: ms.round()));
                        },
                        onChanged: (ms) {
                          _dragNotifier.value = ms;
                          widget.player.setScrubbingPosition(Duration(milliseconds: ms.round()));
                        },
                        onChangeEnd: (ms) {
                          widget.player.seek(Duration(milliseconds: ms.round()));
                          _dragNotifier.value = null;
                          widget.player.setScrubbingPosition(null);
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
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: PlayerVolumeSlider(),
    );
  }
}

/// Volume slider styled as a modern capsule pill.
/// The volume symbol is embedded inside on the left, and the volume percentage
/// number is embedded on the right.
class PlayerVolumeSlider extends StatefulWidget {
  const PlayerVolumeSlider({super.key});

  @override
  State<PlayerVolumeSlider> createState() => _PlayerVolumeSliderState();
}

class _PlayerVolumeSliderState extends State<PlayerVolumeSlider> {
  double? _dragValue;
  double _lastNonZeroVolume = 0.75;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final player = context.watch<PlayerService>();
    final value = (_dragValue ?? player.volume).clamp(0.0, 1.0);

    final volumeIcon = value == 0
        ? Icons.volume_off_rounded
        : (value < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final fillWidth = (totalWidth * value).clamp(0.0, totalWidth);
        final pctText = '${(value * 100).round()}%';

        const inactiveTextColor = Colors.white70;
        final activeTextColor = scheme.onPrimary;

        final inactiveTextStyle = theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 11.5,
          letterSpacing: 0.2,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: inactiveTextColor,
        );

        final activeTextStyle = theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 11.5,
          letterSpacing: 0.2,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: activeTextColor,
        );

        return RepaintBoundary(
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
                final next = (player.volume + delta).clamp(0.0, 1.0);
                if (next > 0) _lastNonZeroVolume = next;
                player.setVolume(next);
                setState(() => _dragValue = next);
              }
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  if (totalWidth <= 0) return;
                  if (details.localPosition.dx <= 40) {
                    if (value > 0) {
                      _lastNonZeroVolume = value;
                      player.setVolume(0.0);
                      setState(() => _dragValue = 0.0);
                    } else {
                      final restore = _lastNonZeroVolume > 0 ? _lastNonZeroVolume : 0.5;
                      player.setVolume(restore);
                      setState(() => _dragValue = restore);
                    }
                    return;
                  }
                  final fraction =
                      (details.localPosition.dx / totalWidth).clamp(0.0, 1.0);
                  if (fraction > 0) _lastNonZeroVolume = fraction;
                  player.setVolume(fraction);
                  setState(() => _dragValue = fraction);
                },
                onHorizontalDragStart: (details) {
                  if (totalWidth <= 0) return;
                  final fraction =
                      (details.localPosition.dx / totalWidth).clamp(0.0, 1.0);
                  if (fraction > 0) _lastNonZeroVolume = fraction;
                  player.setVolume(fraction);
                  setState(() => _dragValue = fraction);
                },
                onHorizontalDragUpdate: (details) {
                  if (totalWidth <= 0) return;
                  final fraction =
                      (details.localPosition.dx / totalWidth).clamp(0.0, 1.0);
                  if (fraction > 0) _lastNonZeroVolume = fraction;
                  player.setVolume(fraction);
                  setState(() => _dragValue = fraction);
                },
                onHorizontalDragEnd: (_) {
                  setState(() => _dragValue = null);
                },
                onHorizontalDragCancel: () {
                  setState(() => _dragValue = null);
                },
                child: SizedBox(
                  height: 36,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      // Inactive track container
                      Container(
                        height: 36,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                      ),

                      // Inactive base layer: icon on left, percentage on right
                      Positioned(
                        left: 12,
                        child: Icon(
                          volumeIcon,
                          size: 18,
                          color: inactiveTextColor,
                        ),
                      ),
                      Positioned(
                        right: 14,
                        child: Text(
                          pctText,
                          style: inactiveTextStyle,
                        ),
                      ),

                      // Active accent fill (clipped to fillWidth)
                      if (fillWidth > 0)
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: fillWidth,
                          child: ClipRRect(
                            borderRadius: BorderRadius.horizontal(
                              left: const Radius.circular(18),
                              right: Radius.circular(value >= 0.96 ? 18 : 6),
                            ),
                            child: Container(
                              color: scheme.primary,
                            ),
                          ),
                        ),

                      // Active text & icon layer clipped to fillWidth
                      if (fillWidth > 0)
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: fillWidth,
                          child: ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.centerLeft,
                              minWidth: totalWidth,
                              maxWidth: totalWidth,
                              child: Stack(
                                alignment: Alignment.centerLeft,
                                children: [
                                  Positioned(
                                    left: 12,
                                    child: Icon(
                                      volumeIcon,
                                      size: 18,
                                      color: scheme.onPrimary,
                                    ),
                                  ),
                                  Positioned(
                                    right: 14,
                                    child: Text(
                                      pctText,
                                      style: activeTextStyle,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
