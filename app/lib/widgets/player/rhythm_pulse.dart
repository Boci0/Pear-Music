import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../services/player_service.dart';

/// Provides a smooth, continuous ambient breathing glow synchronized with playback.
/// Operates on a calm 4-second harmonic cycle with zero physical bouncing or tempo clashing.
/// Employs a state-guarded delayed bloom so that initial buffering or track setup
/// never produces visual flicker or stutter.
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
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _fadeController;
  late final Animation<double> _bloomAnimation;
  bool _wasPlaying = false;

  @override
  void initState() {
    super.initState();
    // 4000ms calm ambient cycle: continuous, smooth, organic
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    );

    // 1400ms growth bloom forward, 500ms smooth shrinking inward on pause
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
      reverseDuration: const Duration(milliseconds: 500),
    );

    _bloomAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInCubic,
      reverseCurve: Curves.easeInQuad,
    );

    _fadeController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        if (_pulseController.isAnimating) {
          _pulseController.stop();
          _pulseController.reset();
        }
      }
    });

    _wasPlaying = widget.player.playing;
    widget.player.addListener(_onPlayerChanged);

    if (_wasPlaying) {
      _pulseController.repeat(reverse: true);
      _fadeController.forward();
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
    final isPlaying = widget.player.playing;
    // CRITICAL: Guard against incidental notifyListeners calls (duration ticks,
    // preload status changes, volume updates). Only transition when playback actually toggles.
    if (isPlaying == _wasPlaying) return;
    _wasPlaying = isPlaying;

    if (isPlaying) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
      _fadeController.forward();
    } else {
      _fadeController.reverse();
      if (_fadeController.isDismissed && _pulseController.isAnimating) {
        _pulseController.stop();
        _pulseController.reset();
      }
    }
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerChanged);
    _pulseController.stop();
    _fadeController.stop();
    _pulseController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseController, _fadeController]),
      builder: (context, child) {
        final bloom = _bloomAnimation.value;
        if (bloom <= 0.0 && !_pulseController.isAnimating) {
          return widget.builder(context, 0.0, widget.child);
        }
        // Continuous harmonic breathing pulse between 0.70 and 1.0
        final t = _pulseController.value;
        final pulse = 0.70 + (0.30 * ((1.0 - math.cos(t * math.pi)) / 2.0));
        // Multiplied by the growth animation so it expands smoothly from exactly 0.0
        final effectiveAura = pulse * bloom;
        return widget.builder(context, effectiveAura, widget.child);
      },
    );
  }
}

