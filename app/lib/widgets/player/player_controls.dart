import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../../services/artwork_palette.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../services/player_service.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../live_seek_bar.dart';
import '../tactile_button.dart';
import 'console_parts.dart';

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
        final effectiveAccent = _signal(accent ?? scheme.primary);
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
        final playbackError = player.playbackError;
        final String? stateLabel = playbackError != null
            ? playbackError.label
            : player.isLoadingRecommendations
                ? 'Finding next tracks...'
                : player.isBuffering
                    ? 'Buffering track...'
                    : null;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LayoutBuilder(builder: (context, box) {
              final row = Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TactileIconButton(
                  iconSize: 24,
                  icon: _ToggleGlyph(
                    icon: Icons.shuffle,
                    active: player.shuffle,
                    accent: effectiveAccent,
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
                  iconSize: 24,
                  icon: _ToggleGlyph(
                    icon: loopIcon,
                    active: loopActive,
                    accent: effectiveAccent,
                  ),
                  tooltip: loopLabel,
                  onPressed: controller.toggleLoop,
                ),
              ],
            );
              // A narrow column (a small phone held sideways) scales the row
              // down instead of overflowing.
              return box.maxWidth < 320
                  ? FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SizedBox(width: 320, child: row),
                    )
                  : row;
            }),
            const SizedBox(height: 2),
            if (stateLabel != null)
              Text(
                stateLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color:
                      playbackError != null ? scheme.error : effectiveAccent,
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

/// Shuffle / repeat glyph: when on, it sits in a soft accent disc so the
/// state reads at a glance instead of only by a colour change.
class _ToggleGlyph extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color accent;
  const _ToggleGlyph({
    required this.icon,
    required this.active,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? accent.withValues(alpha: 0.16) : Colors.transparent,
      ),
      child: Icon(
        icon,
        size: 22,
        color: active ? accent : scheme.onSurfaceVariant,
      ),
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
    final hasError = player.playbackError != null;

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
              message: hasError
                  ? 'Retry'
                  : isBuffering
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
                        color: effectiveColor.withValues(
                          alpha: _isHovered ? 0.30 : 0.22,
                        ),
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
/// whole player screen. The track is one thin line, the played part in the
/// accent; a dot marks the playhead while it is hovered or dragged.
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

  @override
  void dispose() {
    _dragNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final effectiveAccent = _signal(widget.accent ?? colorScheme.primary);
    // A live stream has no length: its bar spans the history YouTube keeps,
    // with the live edge at the right end.
    if (context.select<PlayerService?, bool>((p) => p?.isLive ?? false)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: LiveSeekBar(
          player: widget.player,
          color: effectiveAccent,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final totalMs = widget.duration.inMilliseconds.toDouble();

    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      initialData: widget.player.position ?? Duration.zero,
      builder: (context, snapshot) {
        final pos = snapshot.data ?? Duration.zero;
        final maxMs = totalMs > 0 ? totalMs : 1.0;
        final baseMs = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);

        // RepaintBoundary isolates the ticking line and time-row repaints
        // from the album art and background canvas layers.
        return RepaintBoundary(
          child: ValueListenableBuilder<double?>(
            valueListenable: _dragNotifier,
            builder: (context, dragMs, _) {
              final currentVal = (dragMs ?? baseMs).clamp(0.0, maxMs);
              final progress = (currentVal / maxMs).clamp(0.0, 1.0);
              final current = Duration(milliseconds: currentVal.round());
              final remaining = widget.duration > current
                  ? widget.duration - current
                  : Duration.zero;
              final timeStyle = theme.textTheme.labelSmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w500,
                color: dragMs != null
                    ? effectiveAccent
                    : colorScheme.onSurfaceVariant,
              );
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      double msAt(double dx) =>
                          (dx / width).clamp(0.0, 1.0) * maxMs;
                      void scrub(double dx) {
                        _dragNotifier.value = msAt(dx);
                        widget.player.setScrubbingPosition(
                          Duration(milliseconds: msAt(dx).round()),
                        );
                      }

                      void release(double ms) {
                        widget.player.seek(Duration(milliseconds: ms.round()));
                        _dragNotifier.value = null;
                        widget.player.setScrubbingPosition(null);
                      }

                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        onEnter: (_) => setState(() => _isHovered = true),
                        onExit: (_) => setState(() => _isHovered = false),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) => release(msAt(d.localPosition.dx)),
                          onHorizontalDragStart: (d) =>
                              scrub(d.localPosition.dx),
                          onHorizontalDragUpdate: (d) =>
                              scrub(d.localPosition.dx),
                          onHorizontalDragEnd: (_) =>
                              release(_dragNotifier.value ?? currentVal),
                          onHorizontalDragCancel: () {
                            _dragNotifier.value = null;
                            widget.player.setScrubbingPosition(null);
                          },
                          child: SizedBox(
                            height: 24,
                            width: width,
                            child: CustomPaint(
                              painter: _SeekLinePainter(
                                progress: progress,
                                accent: effectiveAccent,
                                idle: Colors.white.withValues(alpha: 0.16),
                                dot: _isHovered || dragMs != null,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(current), style: timeStyle),
                      GestureDetector(
                        onTap: () =>
                            setState(() => _showRemaining = !_showRemaining),
                        behavior: HitTestBehavior.opaque,
                        child: Text(
                          _showRemaining
                              ? '-${_fmt(remaining)}'
                              : _fmt(widget.duration),
                          style: timeStyle,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  String _fmt(Duration d) {
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final h = d.inHours;
    if (h > 0) {
      final m = (d.inMinutes % 60).toString().padLeft(2, '0');
      return '$h:$m:$s';
    }
    return '${d.inMinutes.toString().padLeft(2, '0')}:$s';
  }
}

/// The seek track: a 3 px rounded line, the played part in the accent, and a
/// round playhead dot while the pointer is on it or a finger drags it.
class _SeekLinePainter extends CustomPainter {
  final double progress;
  final Color accent;
  final Color idle;
  final bool dot;

  const _SeekLinePainter({
    required this.progress,
    required this.accent,
    required this.idle,
    required this.dot,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final x = size.width * progress;
    final paint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), paint..color = idle);
    if (x > 0) {
      canvas.drawLine(Offset(0, y), Offset(x, y), paint..color = accent);
    }
    if (dot) canvas.drawCircle(Offset(x, y), 6, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_SeekLinePainter old) =>
      old.progress != progress ||
      old.accent != accent ||
      old.idle != idle ||
      old.dot != dot;
}

/// Volume icons + slider sharing the compact accent-dot thumb.
class PlayerVolumeRow extends StatelessWidget {
  final Color? accent;
  const PlayerVolumeRow({super.key, this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: PearGlassTokens.cardFill),
        borderRadius: PearRadius.pillAll,
      ),
      child: PlayerVolumeSlider(accent: accent),
    );
  }
}

/// Volume slider: a thin accent thread with a small bead knob, deliberately
/// plainer than the seek bar's glowing cursor.
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

  // Dragging pushes the volume to the player at most every 40 ms: each push
  // notifies the whole player listener tree, and the knob already follows the
  // pointer from local state.
  double? _pendingVolume;
  Timer? _pushTimer;

  void _pushVolume(PlayerService player, double v) {
    if (_pushTimer?.isActive ?? false) {
      _pendingVolume = v;
      return;
    }
    player.setVolume(v);
    _pushTimer = Timer(const Duration(milliseconds: 40), () {
      final pending = _pendingVolume;
      _pendingVolume = null;
      if (pending != null) _pushVolume(player, pending);
    });
  }

  void _flushVolume(PlayerService player) {
    _pushTimer?.cancel();
    final pending = _pendingVolume;
    _pendingVolume = null;
    if (pending != null) player.setVolume(pending);
  }

  @override
  void dispose() {
    _pushTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerService>();
    return ValueListenableBuilder<double>(
      valueListenable: player.volumeNotifier,
      builder: (context, currentVolume, _) =>
          _buildSlider(context, player, currentVolume),
    );
  }

  Widget _buildSlider(
    BuildContext context,
    PlayerService player,
    double currentVolume,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final effectiveAccent = widget.accent ?? scheme.primary;
    final value = (_dragValue ?? currentVolume).clamp(0.0, 1.0);

    final volumeIcon = value == 0
        ? Icons.volume_off_rounded
        : (value < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded);

    final pctText = '${(value * 100).round()}%';
    const double knobSize = 11.0;
    const double trackHeight = 4.5;
    const double containerHeight = 36.0;

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
                  child: PearConsole.on
                      ? Text(
                          value == 0 ? 'MUTE' : 'VOL',
                          style: PearConsole.label(),
                        )
                      : Icon(
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

          // Central volume thread with a bead knob
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final totalWidth = constraints.maxWidth;
                if (totalWidth <= knobSize) return const SizedBox(height: containerHeight);

                final usableWidth = totalWidth - knobSize;
                final knobLeft = value * usableWidth;

                void handleDragUpdate(double localDx) {
                  final fraction = ((localDx - (knobSize / 2)) / usableWidth).clamp(0.0, 1.0);
                  if (fraction > 0) _lastNonZeroVolume = fraction;
                  setState(() => _dragValue = fraction);
                  _pushVolume(player, fraction);
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
                    onHorizontalDragEnd: (_) {
                      _flushVolume(player);
                      setState(() {
                        _isDragging = false;
                        _dragValue = null;
                      });
                    },
                    onHorizontalDragCancel: () {
                      _flushVolume(player);
                      setState(() {
                        _isDragging = false;
                        _dragValue = null;
                      });
                    },
                    child: SizedBox(
                      height: containerHeight,
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.centerLeft,
                        children: [
                          // Unplayed track: same quiet hairline as the seek bar
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: knobSize / 2),
                            child: Container(
                              height: trackHeight,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(trackHeight / 2),
                              ),
                            ),
                          ),

                          // Played track: flat accent, deliberately calmer than
                          // the seek bar so the two never read as twins
                          if (value > 0)
                            Positioned(
                              left: knobSize / 2,
                              child: Container(
                                width: knobLeft,
                                height: trackHeight,
                                decoration: BoxDecoration(
                                  color: effectiveAccent.withValues(alpha: 0.90),
                                  borderRadius: BorderRadius.circular(trackHeight / 2),
                                ),
                              ),
                            ),

                          // Small bead knob
                          Positioned(
                            left: knobLeft,
                            top: (containerHeight - knobSize) / 2,
                            child: IgnorePointer(
                              child: _VolumeKnob(
                                accent: effectiveAccent,
                                active: _isDragging || _isHovered,
                                size: knobSize,
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
            padding: const EdgeInsets.only(left: 8, right: 2),
            child: SizedBox(
              width: 42,
              child: Text(
                PearConsole.on ? '${(value * 100).round()}' : pctText,
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.right,
                style: PearConsole.on
                    ? PearConsole.readout(color: scheme.onSurfaceVariant)
                    : theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
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

/// Small bead knob for the volume thread: flat accent, single soft glow, no
/// playback effects.
class _VolumeKnob extends StatelessWidget {
  final Color accent;
  final bool active;
  final double size;

  const _VolumeKnob({
    required this.accent,
    required this.active,
    this.size = 11.0,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: active ? 1.2 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.rectangle,
          color: accent,
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: active ? 0.45 : 0.28),
              blurRadius: active ? 9 : 6,
            ),
          ],
        ),
      ),
    );
  }
}

/// The controls' accent: the song's colour pushed to its vivid form.
Color _signal(Color accent) => ArtworkPalette.vivid(accent);
