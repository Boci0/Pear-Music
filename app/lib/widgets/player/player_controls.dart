import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../services/player_service.dart';
import '../tactile_button.dart';

/// Previous / play-pause / next transport buttons, flanked by shuffle and
/// repeat controls.
class PlayerTransport extends StatelessWidget {
  final PlayerService player;
  final AppController controller;
  final Color? accent;
  const PlayerTransport({
    super.key,
    required this.player,
    required this.controller,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final effectiveAccent = accent ?? scheme.primary;
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
        final String? stateLabel = player.isLoadingRecommendations
            ? 'Finding next tracks...'
            : player.isBuffering
                ? 'Buffering track...'
                : null;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TactileIconButton(
                  iconSize: 32,
                  icon: Icon(
                    Icons.shuffle,
                    color: player.shuffle
                        ? effectiveAccent
                        : scheme.onSurfaceVariant,
                  ),
                  tooltip: player.shuffle ? 'Shuffle on' : 'Shuffle',
                  onPressed: controller.toggleShuffle,
                ),
                TactileIconButton(
                  iconSize: 44,
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: () => controller.previousTrack(),
                ),
                _PlayPauseButton(
                  player: player,
                  controller: controller,
                  color: effectiveAccent,
                ),
                TactileIconButton(
                  iconSize: 44,
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: () => controller.nextTrack(),
                ),
                TactileIconButton(
                  iconSize: 32,
                  icon: Icon(
                    loopIcon,
                    color: loopActive ? effectiveAccent : scheme.onSurfaceVariant,
                  ),
                  tooltip: loopLabel,
                  onPressed: controller.toggleLoop,
                ),
              ],
            ),
            const SizedBox(height: 2),
            if (stateLabel != null)
              Text(
                stateLabel,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: effectiveAccent,
                ),
              )
            else
              const SizedBox(height: 16),
          ],
        );
      },
    );
  }
}

class _PlayPauseButton extends StatefulWidget {
  final PlayerService player;
  final AppController controller;
  final Color color;

  const _PlayPauseButton({
    required this.player,
    required this.controller,
    required this.color,
  });

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = widget.color;
    const iconColor = Colors.black;
    final player = widget.player;
    final isBuffering = player.isBuffering;
    final isPlaying = player.playing;

    final bgColor = _isPressed
        ? effectiveColor.withValues(alpha: 0.86)
        : (_isHovered
            ? effectiveColor.withValues(alpha: 0.94)
            : effectiveColor);

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
              TactileFeedback.click();
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
                scale: _isPressed ? 0.92 : (_isHovered ? 1.04 : 1.0),
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: bgColor,
                    boxShadow: [
                      BoxShadow(
                        color: effectiveColor.withValues(alpha: _isHovered ? 0.38 : 0.22),
                        blurRadius: _isHovered ? 14 : 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Center(
                    child: isBuffering
                        ? SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 3.0,
                              color: iconColor,
                            ),
                          )
                        : Padding(
                            padding: EdgeInsets.only(left: isPlaying ? 0.0 : 2.5),
                            child: Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: isPlaying ? 34 : 38,
                              color: iconColor,
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
  final Color? accent;
  const PlayerSeekBar({
    super.key,
    required this.player,
    required this.duration,
    this.accent,
  });

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar> {
  final ValueNotifier<double?> _dragNotifier = ValueNotifier(null);
  bool _showRemaining = true;
  bool _isHovered = false;
  bool _isDragging = false;

  @override
  void dispose() {
    _dragNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final effectiveAccent = widget.accent ?? colorScheme.primary;
    final totalMs = widget.duration.inMilliseconds.toDouble();

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
              ValueListenableBuilder<double?>(
                valueListenable: _dragNotifier,
                builder: (context, dragMs, _) {
                  final currentVal = (dragMs ?? baseMs).clamp(0.0, maxMs);
                  final progress = maxMs > 0 ? (currentVal / maxMs).clamp(0.0, 1.0) : 0.0;
                  const double pearSize = 22.0;
                  const double trackHeight = 5.0;
                  const double containerHeight = 32.0;

                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final totalWidth = constraints.maxWidth;
                      if (totalWidth <= pearSize) return const SizedBox(height: containerHeight);

                      final usableWidth = totalWidth - pearSize;
                      final pearLeft = progress * usableWidth;

                      // Rolling angle proportional to distance traveled along the track
                      final rotationAngle = pearLeft / (pearSize / 2);

                      void updatePosition(double localDx, {bool isEnd = false}) {
                        final fraction = ((localDx - (pearSize / 2)) / usableWidth).clamp(0.0, 1.0);
                        final targetMs = fraction * maxMs;
                        if (isEnd) {
                          widget.player.seek(Duration(milliseconds: targetMs.round()));
                          _dragNotifier.value = null;
                          widget.player.setScrubbingPosition(null);
                        } else {
                          _dragNotifier.value = targetMs;
                          widget.player.setScrubbingPosition(Duration(milliseconds: targetMs.round()));
                        }
                      }

                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        onEnter: (_) => setState(() => _isHovered = true),
                        onExit: (_) => setState(() => _isHovered = false),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (details) => updatePosition(details.localPosition.dx, isEnd: true),
                          onHorizontalDragStart: (details) {
                            setState(() => _isDragging = true);
                            updatePosition(details.localPosition.dx);
                          },
                          onHorizontalDragUpdate: (details) => updatePosition(details.localPosition.dx),
                          onHorizontalDragEnd: (details) {
                            setState(() => _isDragging = false);
                            final lastMs = _dragNotifier.value ?? currentVal;
                            widget.player.seek(Duration(milliseconds: lastMs.round()));
                            _dragNotifier.value = null;
                            widget.player.setScrubbingPosition(null);
                          },
                          onHorizontalDragCancel: () {
                            setState(() => _isDragging = false);
                            _dragNotifier.value = null;
                            widget.player.setScrubbingPosition(null);
                          },
                          child: SizedBox(
                            height: containerHeight,
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.centerLeft,
                              children: [
                                // Inactive base track
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: pearSize / 2),
                                  child: Container(
                                    height: trackHeight,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(trackHeight / 2),
                                    ),
                                  ),
                                ),

                                // Active progress track
                                if (progress > 0)
                                  Positioned(
                                    left: pearSize / 2,
                                    child: Container(
                                      width: pearLeft,
                                      height: trackHeight,
                                      decoration: BoxDecoration(
                                        color: effectiveAccent,
                                        borderRadius: BorderRadius.circular(trackHeight / 2),
                                      ),
                                    ),
                                  ),

                                // Rolling Pear thumb
                                Positioned(
                                  left: pearLeft,
                                  top: (containerHeight - pearSize) / 2,
                                  child: IgnorePointer(
                                    child: AnimatedScale(
                                      scale: (_isDragging || _isHovered) ? 1.18 : 1.0,
                                      duration: const Duration(milliseconds: 120),
                                      curve: Curves.easeOutCubic,
                                      child: Container(
                                        width: pearSize,
                                        height: pearSize,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                              color: effectiveAccent.withValues(
                                                alpha: (_isDragging || _isHovered) ? 0.50 : 0.25,
                                              ),
                                              blurRadius: (_isDragging || _isHovered) ? 8.0 : 4.0,
                                              offset: const Offset(0, 1),
                                            ),
                                          ],
                                        ),
                                        child: Transform.rotate(
                                          angle: rotationAngle,
                                          child: Image.asset(
                                            'assets/pear_logo.png',
                                            width: pearSize,
                                            height: pearSize,
                                            color: effectiveAccent,
                                            colorBlendMode: BlendMode.srcIn,
                                            filterQuality: FilterQuality.medium,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
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
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _fmt(currentDuration),
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: dragMs != null ? effectiveAccent : colorScheme.onSurfaceVariant,
                            fontWeight: dragMs != null ? FontWeight.w700 : FontWeight.w600,
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
                              color: dragMs != null ? effectiveAccent : colorScheme.onSurfaceVariant,
                              fontWeight: dragMs != null ? FontWeight.w700 : FontWeight.w600,
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

/// Volume icons + slider with an interactive rolling pear thumb.
class PlayerVolumeRow extends StatelessWidget {
  final Color? accent;
  const PlayerVolumeRow({super.key, this.accent});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: PlayerVolumeSlider(accent: accent),
    );
  }
}

/// Volume slider featuring an adaptive rolling pear thumb that rotates
/// proportionally to travel distance across the track.
class PlayerVolumeSlider extends StatefulWidget {
  final Color? accent;
  const PlayerVolumeSlider({super.key, this.accent});

  @override
  State<PlayerVolumeSlider> createState() => _PlayerVolumeSliderState();
}

class _PlayerVolumeSliderState extends State<PlayerVolumeSlider> {
  double? _dragValue;
  double _lastNonZeroVolume = 0.75;
  bool _isHovered = false;
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final effectiveAccent = widget.accent ?? scheme.primary;
    final player = context.read<PlayerService>();
    final currentVolume = context.select<PlayerService, double>((p) => p.volume);
    final value = (_dragValue ?? currentVolume).clamp(0.0, 1.0);

    final volumeIcon = value == 0
        ? Icons.volume_off_rounded
        : (value < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded);

    final pctText = '${(value * 100).round()}%';
    const double pearSize = 22.0;
    const double trackHeight = 5.0;
    const double containerHeight = 32.0;

    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
          final next = (player.volume + delta).clamp(0.0, 1.0);
          if (next > 0) _lastNonZeroVolume = next;
          setState(() => _dragValue = next);
          player.setVolume(next);
        }
      },
      child: Row(
        children: [
          // Mute / Unmute quick toggle button
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              TactileFeedback.click();
              if (value > 0) {
                _lastNonZeroVolume = value;
                setState(() => _dragValue = 0.0);
                player.setVolume(0.0);
              } else {
                final restore = _lastNonZeroVolume > 0 ? _lastNonZeroVolume : 0.5;
                setState(() => _dragValue = restore);
                player.setVolume(restore);
              }
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Tooltip(
                message: value > 0 ? 'Mute' : 'Unmute',
                child: Padding(
                  padding: const EdgeInsets.only(left: 2, right: 10, top: 4, bottom: 4),
                  child: Icon(
                    volumeIcon,
                    size: 19,
                    color: value == 0
                        ? scheme.onSurfaceVariant.withValues(alpha: 0.45)
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),

          // Central slider track with rolling pear
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final totalWidth = constraints.maxWidth;
                if (totalWidth <= pearSize) return const SizedBox(height: containerHeight);

                final usableWidth = totalWidth - pearSize;
                final pearLeft = value * usableWidth;

                // Rolling angle proportional to distance traveled along the track (theta = x / r)
                final rotationAngle = pearLeft / (pearSize / 2);

                void handleDragUpdate(double localDx) {
                  final fraction = ((localDx - (pearSize / 2)) / usableWidth).clamp(0.0, 1.0);
                  if (fraction > 0) _lastNonZeroVolume = fraction;
                  setState(() => _dragValue = fraction);
                  player.setVolume(fraction);
                }

                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => setState(() => _isHovered = true),
                  onExit: (_) => setState(() => _isHovered = false),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) => handleDragUpdate(details.localPosition.dx),
                    onHorizontalDragStart: (details) {
                      setState(() => _isDragging = true);
                      handleDragUpdate(details.localPosition.dx);
                    },
                    onHorizontalDragUpdate: (details) => handleDragUpdate(details.localPosition.dx),
                    onHorizontalDragEnd: (_) => setState(() {
                      _isDragging = false;
                      _dragValue = null;
                    }),
                    onHorizontalDragCancel: () => setState(() {
                      _isDragging = false;
                      _dragValue = null;
                    }),
                    child: SizedBox(
                      height: containerHeight,
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.centerLeft,
                        children: [
                          // Base track background (inactive)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: pearSize / 2),
                            child: Container(
                              height: trackHeight,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(trackHeight / 2),
                              ),
                            ),
                          ),

                          // Active progress track
                          if (value > 0)
                            Positioned(
                              left: pearSize / 2,
                              child: Container(
                                width: pearLeft,
                                height: trackHeight,
                                decoration: BoxDecoration(
                                  color: effectiveAccent,
                                  borderRadius: BorderRadius.circular(trackHeight / 2),
                                ),
                              ),
                            ),

                          // Rolling Pear thumb
                          Positioned(
                            left: pearLeft,
                            top: (containerHeight - pearSize) / 2,
                            child: IgnorePointer(
                              child: AnimatedScale(
                                scale: (_isDragging || _isHovered) ? 1.18 : 1.0,
                                duration: const Duration(milliseconds: 120),
                                curve: Curves.easeOutCubic,
                                child: Container(
                                  width: pearSize,
                                  height: pearSize,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: effectiveAccent.withValues(
                                          alpha: (_isDragging || _isHovered) ? 0.50 : 0.25,
                                        ),
                                        blurRadius: (_isDragging || _isHovered) ? 8.0 : 4.0,
                                        offset: const Offset(0, 1),
                                      ),
                                    ],
                                  ),
                                  child: Transform.rotate(
                                    angle: rotationAngle,
                                    child: Image.asset(
                                      'assets/pear_logo.png',
                                      width: pearSize,
                                      height: pearSize,
                                      color: effectiveAccent,
                                      colorBlendMode: BlendMode.srcIn,
                                      filterQuality: FilterQuality.medium,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          // Percentage readout
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 2),
            child: SizedBox(
              width: 32,
              child: Text(
                pctText,
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
