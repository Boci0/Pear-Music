import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../services/ambient_ticker.dart';
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
    with WidgetsBindingObserver {
  /// Phase of the 4 s breath, ping-ponging between 0 and 1 via [_pulseDir].
  double _pulsePhase = 0.0;
  int _pulseDir = 1;
  bool _pulseRunning = false;

  /// Bloom in/out progress: 0 to 1 in 1400 ms, back down in 500 ms.
  double _fadePhase = 0.0;
  int _fadeDir = 1;

  bool _ticking = false;
  bool _wasPlaying = false;
  bool _isAppForeground = true;
  bool _windowFocused = true;

  /// Quantized aura value (0.005 steps). The halo is a slow 4 s ambient
  /// breath, so rebuilding the halo 60 times per second buys nothing
  /// visually while adding layer churn and repaints on every frame. Steps of
  /// 0.5% opacity are imperceptible on a diffuse glow.
  final ValueNotifier<double> _aura = ValueNotifier<double>(0.0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wasPlaying = widget.player.playing;
    widget.player.addListener(_onPlayerChanged);
    _windowFocused = WindowFocus.focused.value;
    WindowFocus.focused.addListener(_onWindowFocusChanged);

    _syncPulse();
  }

  void _startTicking() {
    if (_ticking) return;
    _ticking = true;
    AmbientTicker.instance.addListener(_onAmbientTick);
  }

  void _stopTicking() {
    if (!_ticking) return;
    _ticking = false;
    AmbientTicker.instance.removeListener(_onAmbientTick);
  }

  /// Advances the breath and bloom phases. Runs at 30 Hz: the loops are slow
  /// glows, so this looks identical to every-frame updates while leaving the
  /// display's full frame rate to interactive motion.
  void _onAmbientTick(Duration step) {
    final dt = step.inMicroseconds / 1000000.0;
    if (_fadeDir > 0) {
      _fadePhase = (_fadePhase + dt / 1.4).clamp(0.0, 1.0);
    } else {
      _fadePhase = (_fadePhase - dt / 0.5).clamp(0.0, 1.0);
      if (_fadePhase <= 0.0) {
        // No bloom left to light: park until playback resumes.
        _pulseRunning = false;
        _pulsePhase = 0.0;
        _pulseDir = 1;
        _stopTicking();
      }
    }
    if (_pulseRunning) {
      _pulsePhase += _pulseDir * dt / 4.0;
      if (_pulsePhase >= 1.0) {
        _pulsePhase = 1.0;
        _pulseDir = -1;
      } else if (_pulsePhase <= 0.0) {
        _pulsePhase = 0.0;
        _pulseDir = 1;
      }
    }
    _recomputeAura();
  }

  double get _bloom =>
      (_fadeDir > 0 ? Curves.easeInCubic : Curves.easeInQuad)
          .transform(_fadePhase);

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
      _pulseRunning = true;
      _fadeDir = 1;
      _startTicking();
    } else {
      _fadeDir = -1;
      if (_fadePhase > 0.0) {
        // Ease the bloom out, then park.
        _startTicking();
      } else {
        _pulseRunning = false;
        _pulsePhase = 0.0;
        _pulseDir = 1;
        _stopTicking();
      }
    }
    _recomputeAura();
  }

  /// Recomputes the quantized aura. Called on every ambient tick (cheap
  /// arithmetic) but only notifies when the quantized value actually changes.
  void _recomputeAura() {
    double raw;
    if (_fadePhase <= 0.0 && !_pulseRunning) {
      raw = 0.0;
    } else {
      // Continuous harmonic breathing pulse between 0.70 and 1.0.
      final pulse =
          0.70 + (0.30 * ((1.0 - math.cos(_pulsePhase * math.pi)) / 2.0));
      raw = pulse * _bloom;
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
    _stopTicking();
    _aura.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilds only when the quantized aura changes (see [_recomputeAura]),
    // not on every ambient tick.
    return ValueListenableBuilder<double>(
      valueListenable: _aura,
      builder: (context, aura, _) => widget.builder(context, aura, widget.child),
    );
  }
}

