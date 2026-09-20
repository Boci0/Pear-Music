import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../services/player_service.dart';
import '../../services/window_focus.dart';

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
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _pulseController;
  late final AnimationController _fadeController;
  late final Animation<double> _bloomAnimation;
  bool _wasPlaying = false;
  bool _isAppForeground = true;
  bool _windowFocused = true;

  /// Quantized aura value (0.005 steps). The halo is a slow 4 s ambient
  /// breath, so rebuilding the Opacity widget 60 times per second buys nothing
  /// visually while adding layer churn and repaints on every frame. Steps of
  /// 0.5% opacity are imperceptible on a diffuse glow.
  final ValueNotifier<double> _aura = ValueNotifier<double>(0.0);

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
      _recomputeAura();
    });
    _pulseController.addListener(_recomputeAura);
    _fadeController.addListener(_recomputeAura);

    WidgetsBinding.instance.addObserver(this);
    _wasPlaying = widget.player.playing;
    widget.player.addListener(_onPlayerChanged);
    _windowFocused = WindowFocus.focused.value;
    WindowFocus.focused.addListener(_onWindowFocusChanged);

    _syncPulse();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    if (_isAppForeground != isForeground) {
      _isAppForeground = isForeground;
      _syncPulse();
    }
  }

  void _onWindowFocusChanged() {
    final focused = WindowFocus.focused.value;
    if (_windowFocused == focused) return;
    _windowFocused = focused;
    _syncPulse();
  }

  /// True when the app is in the foreground and the window is the active one.
  bool get _canPulse => _isAppForeground && _windowFocused;

  /// Runs the breathing pulse while playing and visible, or eases it out.
  void _syncPulse() {
    if (widget.player.playing && _canPulse) {
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
    _recomputeAura();
  }

  /// Recomputes the quantized aura. Called on every controller tick (cheap
  /// arithmetic) but only notifies when the quantized value actually changes.
  void _recomputeAura() {
    final bloom = _bloomAnimation.value;
    double raw;
    if (bloom <= 0.0 && !_pulseController.isAnimating) {
      raw = 0.0;
    } else {
      // Continuous harmonic breathing pulse between 0.70 and 1.0.
      final t = _pulseController.value;
      final pulse = 0.70 + (0.30 * ((1.0 - math.cos(t * math.pi)) / 2.0));
      raw = pulse * bloom;
    }
    final quantized = (raw * 200).roundToDouble() / 200; // 0.005 steps
    if (quantized != _aura.value) _aura.value = quantized;
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
    _syncPulse();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.player.removeListener(_onPlayerChanged);
    WindowFocus.focused.removeListener(_onWindowFocusChanged);
    _pulseController.stop();
    _fadeController.stop();
    _pulseController.removeListener(_recomputeAura);
    _fadeController.removeListener(_recomputeAura);
    _aura.dispose();
    _pulseController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilds only when the quantized aura changes (see [_recomputeAura]),
    // not on every 60 fps controller tick.
    return ValueListenableBuilder<double>(
      valueListenable: _aura,
      builder: (context, aura, _) => widget.builder(context, aura, widget.child),
    );
  }
}

