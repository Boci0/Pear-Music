import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../controllers/app_controller.dart';
import '../../services/player_service.dart';
import '../../theme/pear_style.dart';
import '../tactile_button.dart';

/// The Console look for the desktop player under Graphite: hardware-style
/// read-outs, a segmented progress bar, square buttons and monospaced times.
/// Phones and the other styles keep their own player parts.
class PearConsole {
  PearConsole._();

  static bool get on =>
      PearStyles.spec.angular &&
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Monospaced figures for times and counters.
  static TextStyle readout({double size = 13, Color? color}) => TextStyle(
        fontFamily: 'Consolas',
        fontFamilyFallback: const ['Cascadia Mono', 'Courier New', 'monospace'],
        fontSize: size,
        height: 1.1,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: color,
      );

  /// Spaced capitals for labels (VOL, NOW PLAYING).
  static TextStyle label({Color? color}) => TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.6,
        color: color ?? Colors.white.withValues(alpha: 0.5),
      );

  static Color get rule => Colors.white.withValues(alpha: 0.14);

  static String clock(Duration d) {
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }
}

/// Segmented progress with the elapsed time (accent) and the length under it.
/// Click or drag along the segments to seek; the bar follows the pointer and
/// seeks on release.
class ConsoleSeekBar extends StatefulWidget {
  const ConsoleSeekBar({
    super.key,
    required this.player,
    required this.duration,
    required this.accent,
  });

  final PlayerService player;
  final Duration duration;
  final Color accent;

  @override
  State<ConsoleSeekBar> createState() => _ConsoleSeekBarState();
}

class _ConsoleSeekBarState extends State<ConsoleSeekBar> {
  double? _drag;

  void _seekTo(double fraction, Duration total) {
    widget.player.seek(total * fraction);
    setState(() => _drag = null);
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final muted = Colors.white.withValues(alpha: 0.45);
    if (player.isLive) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text('LIVE', style: PearConsole.label(color: widget.accent)),
      );
    }
    return RepaintBoundary(
      child: StreamBuilder<Duration>(
        stream: player.uiPositionStream,
        initialData: player.position ?? Duration.zero,
        builder: (context, snap) {
          final known = player.currentSong?.durationMs;
          // The song's stored length stands in until the player reports one.
          final total = widget.duration > Duration.zero
              ? widget.duration
              : (player.duration ??
                  Duration(milliseconds: known ?? 0));
          final totalMs = total.inMilliseconds;
          final played = totalMs <= 0
              ? 0.0
              : ((snap.data ?? Duration.zero).inMilliseconds / totalMs)
                  .clamp(0.0, 1.0);
          final value = _drag ?? played;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LayoutBuilder(
                builder: (context, box) {
                  double at(double dx) => (dx / box.maxWidth).clamp(0.0, 1.0);
                  return MouseRegion(
                    cursor: totalMs > 0
                        ? SystemMouseCursors.click
                        : MouseCursor.defer,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: totalMs <= 0
                          ? null
                          : (d) => _seekTo(at(d.localPosition.dx), total),
                      onHorizontalDragUpdate: totalMs <= 0
                          ? null
                          : (d) =>
                              setState(() => _drag = at(d.localPosition.dx)),
                      onHorizontalDragEnd: totalMs <= 0
                          ? null
                          : (_) => _seekTo(_drag ?? played, total),
                      child: SizedBox(
                        height: 18,
                        child: CustomPaint(
                          size: Size(box.maxWidth, 18),
                          painter: _SegmentsPainter(
                            fraction: value,
                            lit: widget.accent,
                            idle: Colors.white.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    PearConsole.clock(total * value),
                    style: PearConsole.readout(size: 15, color: widget.accent),
                  ),
                  const Spacer(),
                  Text(
                    PearConsole.clock(total),
                    style: PearConsole.readout(size: 15, color: muted),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SegmentsPainter extends CustomPainter {
  _SegmentsPainter({
    required this.fraction,
    required this.lit,
    required this.idle,
  });

  final double fraction;
  final Color lit;
  final Color idle;

  static const double _pitch = 7;
  static const double _gap = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final count = (size.width / _pitch).floor().clamp(1, 400);
    final w = (size.width - _gap * (count - 1)) / count;
    final litCount = fraction * count;
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      paint.color = Color.lerp(idle, lit, (litCount - i).clamp(0.0, 1.0))!;
      canvas.drawRect(
        Rect.fromLTWH(i * (w + _gap), 0, w, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SegmentsPainter old) =>
      old.fraction != fraction || old.lit != lit || old.idle != idle;
}

/// Shuffle, previous, play, next and repeat in one framed strip, with a
/// square play key. The error or buffering line sits under it as before.
class ConsoleTransport extends StatelessWidget {
  const ConsoleTransport({
    super.key,
    required this.player,
    required this.controller,
    required this.accent,
  });

  final PlayerService player;
  final AppController controller;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final error = player.playbackError;
        final state = error != null
            ? error.label
            : player.isLoadingRecommendations
                ? 'Finding next tracks...'
                : player.isBuffering
                    ? 'Buffering track...'
                    : null;
        Widget toggle(IconData icon, bool active, String tip, VoidCallback f) =>
            TactileIconButton(
              iconSize: 20,
              icon: Icon(
                icon,
                color: active ? accent : scheme.onSurfaceVariant,
              ),
              tooltip: tip,
              onPressed: f,
            );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: PearConsole.rule),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  toggle(
                    Icons.shuffle,
                    player.shuffle,
                    player.shuffle ? 'Shuffle on' : 'Shuffle',
                    controller.toggleShuffle,
                  ),
                  TactileIconButton(
                    iconSize: 28,
                    icon: const Icon(Icons.skip_previous_rounded),
                    tooltip: 'Previous',
                    onPressed: () => controller.previousTrack(),
                  ),
                  TactileBounce(
                    onTap: () => controller.togglePlayback(),
                    scaleDown: 0.92,
                    tooltip: error != null
                        ? 'Retry'
                        : player.playing
                            ? 'Pause'
                            : 'Play',
                    child: Container(
                      width: 64,
                      height: 40,
                      color: accent,
                      alignment: Alignment.center,
                      child: player.isBuffering
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.black,
                              ),
                            )
                          : Icon(
                              player.playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 28,
                              color: Colors.black,
                            ),
                    ),
                  ),
                  TactileIconButton(
                    iconSize: 28,
                    icon: const Icon(Icons.skip_next_rounded),
                    tooltip: 'Next',
                    onPressed: () => controller.nextTrack(),
                  ),
                  toggle(
                    player.loopMode == LoopSetting.one
                        ? Icons.repeat_one
                        : Icons.repeat,
                    player.loopMode != LoopSetting.off,
                    switch (player.loopMode) {
                      LoopSetting.one => 'Repeat one (this song)',
                      LoopSetting.all => 'Repeat all (album)',
                      LoopSetting.off => 'No repeat',
                    },
                    controller.toggleLoop,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            if (state != null)
              Text(
                state,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: error != null ? scheme.error : accent,
                    ),
              )
            else
              const SizedBox(height: 14),
          ],
        );
      },
    );
  }
}
