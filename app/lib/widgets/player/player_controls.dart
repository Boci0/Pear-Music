import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../services/player_service.dart';
import '../../services/window_focus.dart';
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
/// whole player screen. The track is drawn as a per-track waveform with a
/// pearl playhead riding on top; its ripple and bloom run only while audio
/// plays and the window is focused.
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

class _PlayerSeekBarState extends State<PlayerSeekBar>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<double?> _dragNotifier = ValueNotifier(null);
  bool _showRemaining = true;
  bool _isHovered = false;
  bool _isDragging = false;

  /// Drives the cursor bloom breathing. Parked (no ticks, no repaints)
  /// whenever playback or the window is idle.
  late final AnimationController _glowController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );
  bool _glowRunning = false;
  bool _wasPlaying = false;
  bool _windowFocused = true;

  /// Quantized sample of [_glowController]: the 3.2 s cycle advances ~0.011 per
  /// step, i.e. ~28 updates per second. The ripple and the bead bloom are slow
  /// ambient motions, so this looks identical to updating every frame while
  /// halving the repaint/rebuild traffic on 60/120 Hz displays.
  final ValueNotifier<double> _waveTick = ValueNotifier<double>(0.0);

  void _onGlowTick() {
    final quantized = (_glowController.value * 90).floorToDouble() / 90;
    if (quantized != _waveTick.value) _waveTick.value = quantized;
  }

  @override
  void initState() {
    super.initState();
    _wasPlaying = widget.player.playing;
    widget.player.addListener(_onPlayerChanged);
    _glowController.addListener(_onGlowTick);
    _windowFocused = WindowFocus.focused.value;
    WindowFocus.focused.addListener(_onWindowFocusChanged);
    // Seed the initial state directly; the first build follows the mount.
    _glowRunning = _wasPlaying && _windowFocused && !_isDragging;
    if (_glowRunning) {
      _glowController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant PlayerSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerChanged);
      widget.player.addListener(_onPlayerChanged);
      _wasPlaying = widget.player.playing;
      _syncGlow();
    }
  }

  void _onPlayerChanged() {
    final isPlaying = widget.player.playing;
    // Ignore incidental notifications (position ticks, preload updates) and
    // only react when playback actually toggles.
    if (isPlaying == _wasPlaying) return;
    _wasPlaying = isPlaying;
    _syncGlow();
  }

  void _onWindowFocusChanged() {
    final focused = WindowFocus.focused.value;
    if (_windowFocused == focused) return;
    _windowFocused = focused;
    _syncGlow();
  }

  /// Runs the bloom only while audio plays, the window is focused, and the
  /// user is not scrubbing.
  void _syncGlow() {
    final shouldRun = _wasPlaying && _windowFocused && !_isDragging;
    if (shouldRun == _glowRunning) return;
    _glowRunning = shouldRun;
    if (shouldRun) {
      _glowController.repeat();
    } else {
      _glowController.stop();
      _glowController.reset();
      _waveTick.value = 0.0;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerChanged);
    WindowFocus.focused.removeListener(_onWindowFocusChanged);
    _glowController.removeListener(_onGlowTick);
    _waveTick.dispose();
    _glowController.dispose();
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
                  const double nubWidth = _PlayheadNub.width;
                  const double containerHeight = 32.0;

                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final totalWidth = constraints.maxWidth;
                      if (totalWidth <= nubWidth) return const SizedBox(height: containerHeight);

                      final usableWidth = totalWidth - nubWidth;
                      final headX = progress * usableWidth;

                      void updatePosition(double localDx, {bool isEnd = false}) {
                        final fraction = ((localDx - (nubWidth / 2)) / usableWidth).clamp(0.0, 1.0);
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
                            _syncGlow();
                            updatePosition(details.localPosition.dx);
                          },
                          onHorizontalDragUpdate: (details) => updatePosition(details.localPosition.dx),
                          onHorizontalDragEnd: (details) {
                            setState(() => _isDragging = false);
                            _syncGlow();
                            final lastMs = _dragNotifier.value ?? currentVal;
                            widget.player.seek(Duration(milliseconds: lastMs.round()));
                            _dragNotifier.value = null;
                            widget.player.setScrubbingPosition(null);
                          },
                          onHorizontalDragCancel: () {
                            setState(() => _isDragging = false);
                            _syncGlow();
                            _dragNotifier.value = null;
                            widget.player.setScrubbingPosition(null);
                          },
                          child: SizedBox(
                            height: containerHeight,
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.centerLeft,
                              children: [
                                // Waveform track: played bars in accent, the
                                // rest dim; a ripple travels along it while
                                // audio runs
                                Positioned(
                                  left: nubWidth / 2,
                                  top: 0,
                                  bottom: 0,
                                  width: usableWidth,
                                  child: CustomPaint(
                                    painter: _WaveformPainter(
                                      progress: progress,
                                      accent: effectiveAccent,
                                      idleColor: Colors.white.withValues(alpha: 0.13),
                                      seed: widget.player.currentSong?.id.hashCode ?? 0,
                                      wave: _glowRunning ? _waveTick : null,
                                    ),
                                  ),
                                ),

                                // Pearl playhead; its bloom breathes softly
                                // while the track plays
                                Positioned(
                                  left: headX,
                                  top: (containerHeight - _PlayheadNub.height) / 2,
                                  child: IgnorePointer(
                                    child: ValueListenableBuilder<double>(
                                      valueListenable: _waveTick,
                                      builder: (context, waveValue, _) => _PlayheadNub(
                                        accent: effectiveAccent,
                                        active: _isDragging || _isHovered,
                                        pulse: _glowRunning
                                            ? 0.5 - 0.5 * math.cos(waveValue * 2 * math.pi)
                                            : 0.0,
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
                    padding: const EdgeInsets.symmetric(horizontal: 6),
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

/// Volume icons + slider sharing the compact accent-dot thumb.
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
    const double knobSize = 11.0;
    const double trackHeight = 3.5;
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
                pctText,
                maxLines: 1,
                softWrap: false,
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

/// Round pearl playhead for the seek waveform: a circle reads as a handle
/// against the vertical bars, and it is sized larger than the tallest bar.
/// Grows on hover or drag; its bloom breathes with [pulse] while the track
/// plays.
class _PlayheadNub extends StatelessWidget {
  /// Bead diameter, also used by the layout to reserve travel space.
  static const double width = 16.0;

  /// Same as [width]; the bead is round.
  static const double height = 16.0;

  final Color accent;
  final bool active;

  /// 0..1 playback pulse that gently brightens and widens the bloom.
  final double pulse;

  const _PlayheadNub({
    required this.accent,
    required this.active,
    this.pulse = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: active ? 1.22 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: const Alignment(-0.35, -0.4),
            radius: 0.9,
            colors: [
              Colors.white,
              Color.lerp(accent, Colors.white, 0.50)!,
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.55 + pulse * 0.35),
              blurRadius: 12 + pulse * 8,
            ),
            BoxShadow(
              color: accent.withValues(alpha: 0.22 + pulse * 0.20),
              blurRadius: 24 + pulse * 14,
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws the seek track as a mirrored waveform. Bar heights come from layered
/// sines plus an index hash (so each track gets a stable pattern), played bars
/// warm toward white just behind the cursor, and a slow ripple travels along
/// the bars whenever [wave] is ticking.
class _WaveformPainter extends CustomPainter {
  final double progress;
  final Color accent;
  final Color idleColor;
  final int seed;

  /// 30 Hz sampled glow-controller value (see [_PlayerSeekBarState._waveTick]).
  /// Drives the travelling ripple; drives [CustomPainter.repaint] so the track
  /// picture is only re-recorded when the sample actually changes.
  final ValueNotifier<double>? wave;

  static const double _barWidth = 2.5;
  static const double _gap = 2.5;
  static const double _minHeight = 4.0;
  static const double _maxHeight = 15.0;

  _WaveformPainter({
    required this.progress,
    required this.accent,
    required this.idleColor,
    required this.seed,
    required this.wave,
  }) : super(repaint: wave);

  @override
  void paint(Canvas canvas, Size size) {
    final pitch = _barWidth + _gap;
    final count = (size.width / pitch).floor();
    if (count <= 0) return;

    final centerY = size.height / 2;
    final headLocal = progress * size.width;
    final phase = wave == null ? 0.0 : wave!.value * 2 * math.pi;
    final paint = Paint()..style = PaintingStyle.fill;
    // Warm tint for bars behind the cursor. Color.lerp is linear, so lerping
    // toward this precomputed colour by [closeness] is pixel-identical to the
    // old per-bar double lerp while allocating nothing inside the loop.
    final warmFull = Color.lerp(accent, Color.lerp(accent, Colors.white, 0.8)!, 0.22)!;

    for (var i = 0; i < count; i++) {
      final left = i * pitch;
      // Layered sines give a musical envelope; the hash keeps it organic.
      final envelope = 0.55 +
          0.30 * math.sin(i * 0.18 + 0.9) +
          0.15 * math.sin(i * 0.045 + 2.1);
      var height = _minHeight +
          (_maxHeight - _minHeight) *
              (envelope * (0.72 + 0.5 * _noise(i))).clamp(0.0, 1.0);
      if (wave != null) {
        height *= 1 + 0.16 * math.sin(phase + i * 0.55);
      }
      height = height.clamp(2.0, _maxHeight + 2.0);

      final barCenter = left + _barWidth / 2;
      if (barCenter <= headLocal) {
        // Bars just behind the cursor warm toward white, kept subtle so the
        // playhead bead stays the brightest thing on the track.
        final closeness = ((headLocal - left) / 22).clamp(0.0, 1.0);
        paint.color = closeness >= 1.0
            ? warmFull
            : Color.lerp(accent, warmFull, closeness)!;
      } else {
        paint.color = idleColor;
      }

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, centerY - height / 2, _barWidth, height),
          const Radius.circular(_barWidth / 2),
        ),
        paint,
      );
    }
  }

  double _noise(int i) {
    final v = math.sin((i + seed) * 12.9898) * 43758.5453;
    return (v - v.floorToDouble()).clamp(0.0, 1.0);
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.accent != accent ||
        oldDelegate.idleColor != idleColor ||
        oldDelegate.seed != seed ||
        oldDelegate.wave != wave;
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
          shape: BoxShape.circle,
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
