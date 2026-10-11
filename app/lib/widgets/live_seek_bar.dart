import 'dart:async';

import 'package:flutter/material.dart';

import '../services/live_hls_proxy.dart';
import '../services/player_service.dart';
import 'live_badge.dart';

/// Shortest history worth a seek bar: below this the stream is shown as just
/// "LIVE" (a broadcast with no DVR keeps a minute or two at most).
const double _minRewindWindow = 60;

/// The seek bar of a live stream: the left end is the oldest audio YouTube
/// still keeps, the right end is live. Dragging it rewinds (the stream is
/// reopened where the drag ends), and "Go live" returns to the edge.
///
/// [compact] puts everything on one line for the Now Playing pane.
class LiveSeekBar extends StatefulWidget {
  const LiveSeekBar({
    super.key,
    required this.player,
    required this.color,
    this.style,
    this.compact = false,
  });

  final PlayerService player;
  final Color color;
  final TextStyle? style;
  final bool compact;

  @override
  State<LiveSeekBar> createState() => _LiveSeekBarState();
}

class _LiveSeekBarState extends State<LiveSeekBar> {
  /// Slider value (seconds from the oldest audio) while a drag is going on.
  double? _drag;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // A paused stream falls behind the edge a second at a time; while playing
    // nothing moves, so nothing is redrawn.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !widget.player.playing) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static String _clock(double seconds) {
    final s = seconds.round();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = (s % 60).toString().padLeft(2, '0');
    return h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:$sec'
        : '$m:$sec';
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return ListenableBuilder(
      listenable: Listenable.merge([player, LiveHlsProxy.windowSeconds]),
      builder: (context, _) {
        final window = player.liveWindow;
        if (window < _minRewindWindow) {
          // Nothing to rewind into (yet): the plain live row.
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const LiveBadge(),
              const SizedBox(width: 8),
              Flexible(
                child: LiveLabel(style: widget.style, compact: widget.compact),
              ),
            ],
          );
        }
        final behind = player.liveBehind.clamp(0.0, window).toDouble();
        final value = (_drag ?? window - behind).clamp(0.0, window).toDouble();
        final shown = window - value;
        final away = shown > PlayerService.liveCloseEnough;

        final label = SizedBox(
          width: 52,
          child: away
              ? Text('-${_clock(shown)}',
                  maxLines: 1,
                  style: widget.style?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ))
              : const Align(
                  alignment: Alignment.centerLeft,
                  child: LiveBadge(),
                ),
        );
        final slider = SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: widget.color,
            inactiveTrackColor: widget.color.withValues(alpha: 0.25),
            thumbColor: widget.color,
          ),
          child: Slider(
            min: 0,
            max: window,
            value: value,
            onChanged: (v) => setState(() => _drag = v),
            onChangeEnd: (v) {
              setState(() => _drag = null);
              unawaited(player.seekLive(window - v));
            },
          ),
        );
        final goLive = TextButton(
          onPressed: () => unawaited(player.goLive()),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            foregroundColor: widget.color,
          ),
          child: const Text('Go live'),
        );

        if (widget.compact) {
          return Row(
            children: [
              label,
              Expanded(child: slider),
              away
                  ? goLive
                  : Flexible(
                      child: LiveLabel(style: widget.style, compact: true),
                    ),
            ],
          );
        }
        // The bar spans the full width; below it one centred line says where
        // playback is (LIVE, or how far back) and how much data it has used.
        // Fixed height, so Go live appearing does not push the controls.
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            slider,
            SizedBox(
              height: 36,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  away
                      ? Text('-${_clock(shown)}',
                          maxLines: 1,
                          style: widget.style?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ))
                      : const LiveBadge(),
                  const SizedBox(width: 8),
                  Flexible(
                    child: LiveLabel(style: widget.style, compact: away),
                  ),
                  if (away) goLive,
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
