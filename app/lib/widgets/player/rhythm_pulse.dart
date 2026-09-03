import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../services/player_service.dart';

/// Provides a smooth, continuous ambient breathing glow synchronized with playback.
/// Operates on a calm 4-second harmonic cycle with zero physical bouncing or tempo clashing.
class RhythmPulseBuilder extends StatefulWidget {
  final PlayerService player;
  final Widget Function(BuildContext context, double aura, Widget? child) builder;
  final Widget? child;

  const RhythmPulseBuilder({
    super.key,
    required this.player,
    required this.builder,
    this.child,
  });

  @override
  State<RhythmPulseBuilder> createState() => _RhythmPulseBuilderState();
}

class _RhythmPulseBuilderState extends State<RhythmPulseBuilder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // 4000ms calm ambient cycle: continuous, smooth, organic
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    );

    widget.player.addListener(_onPlayerChanged);
    if (widget.player.playing) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant RhythmPulseBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerChanged);
      widget.player.addListener(_onPlayerChanged);
      _onPlayerChanged();
    }
  }

  void _onPlayerChanged() {
    if (widget.player.playing) {
      if (!_controller.isAnimating) {
        _controller.repeat(reverse: true);
      }
    } else {
      if (_controller.isAnimating) {
        _controller.animateTo(
          0.0,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOut,
        );
      }
    }
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // Smooth sine-smoothed aura between 0.0 and 1.0
        final t = _controller.value;
        final aura = (1.0 - math.cos(t * math.pi)) / 2.0;
        return widget.builder(context, aura, widget.child);
      },
    );
  }
}

