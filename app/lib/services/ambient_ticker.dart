import 'dart:async';

/// Shared 30 Hz clock for the player's ambient glows.
///
/// The halo breath and the seek-bar shimmer are slow loops whose visible
/// values only step 15 to 30 times per second. Driving them from the display
/// vsync makes the engine render and composite the whole player scene 60
/// times a second for motion nobody can see; while these loops are the only
/// animations alive, this ticker paces frame requests at half that rate
/// instead. Interactive animations (ripples, fades, the visualizer) keep
/// their own tickers and stay at the full display rate.
class AmbientTicker {
  AmbientTicker._();

  static final AmbientTicker instance = AmbientTicker._();

  /// Fixed step between ticks. Consumers advance their loops by this duration
  /// rather than wall-clock time, which keeps behaviour identical under the
  /// fake clocks widget tests use.
  static const Duration step = Duration(milliseconds: 33);

  final List<void Function(Duration step)> _listeners = [];
  Timer? _timer;

  void addListener(void Function(Duration step) listener) {
    if (_listeners.contains(listener)) return;
    _listeners.add(listener);
    _timer ??= Timer.periodic(step, (_) => _tick());
  }

  void removeListener(void Function(Duration step) listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _tick() {
    // Copy so listeners may unregister from inside a tick.
    for (final listener in List<void Function(Duration step)>.of(_listeners)) {
      listener(step);
    }
  }
}
