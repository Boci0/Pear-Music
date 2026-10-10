import 'dart:async';

/// Shared clock for the player's ambient glows.
///
/// The halo breath and the seek-bar shimmer are slow loops. Driving them from
/// the display vsync makes the engine render and composite the whole player
/// scene 60 times a second for motion nobody can see, so they run from this
/// clock instead, and consumers share it so that their updates land on the
/// same tick and cost one frame between them rather than one each.
///
/// The clock beats every [step]. A listener asks to run on every [every]th
/// beat and is handed the time that covers (`step * every`), so a loop that
/// advances by the step it is given keeps its real speed at any rate. Slow,
/// soft glows ask for a low rate (about 15 updates a second is smooth for
/// them); the visualizer's bars, which are meant to be lively, can ask for
/// every beat.
class AmbientTicker {
  AmbientTicker._();

  static final AmbientTicker instance = AmbientTicker._();

  /// The beat of the clock. Consumers advance their loops by the step they are
  /// handed rather than by wall-clock time, which keeps behaviour identical
  /// under the fake clocks widget tests use.
  static const Duration step = Duration(milliseconds: 33);

  final Map<void Function(Duration step), int> _listeners = {};
  Timer? _timer;
  int _beat = 0;

  void addListener(void Function(Duration step) listener, {int every = 1}) {
    if (_listeners.containsKey(listener)) return;
    _listeners[listener] = every < 1 ? 1 : every;
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
    _beat++;
    // Copy so listeners may unregister from inside a tick.
    for (final entry in List.of(_listeners.entries)) {
      if (!_listeners.containsKey(entry.key)) continue;
      if (_beat % entry.value != 0) continue;
      entry.key(step * entry.value);
    }
  }
}
