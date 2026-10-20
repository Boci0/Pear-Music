import 'dart:async';

/// The player's sleep timer: either a countdown, or "stop after this song" /
/// "stop after the queue". It only holds the timer state; [onExpire] is what
/// the player does when the countdown ends.
class SleepTimer {
  SleepTimer({required this.onExpire});

  final Future<void> Function() onExpire;

  Timer? _timer;
  DateTime? _endTime;
  bool _endOfSong = false;
  bool _endOfQueue = false;

  bool get isActive => _timer != null || _endOfSong || _endOfQueue;
  Duration? get remaining => _endTime?.difference(DateTime.now());
  bool get endOfSong => _endOfSong;
  bool get endOfQueue => _endOfQueue;

  /// Replaces any running timer. [duration] is ignored when one of the
  /// end-of modes is set.
  void set(Duration? duration, {bool endOfSong = false, bool endOfQueue = false}) {
    cancel();
    _endOfSong = endOfSong;
    _endOfQueue = endOfQueue;
    if (endOfSong || endOfQueue) return;
    if (duration != null && duration > Duration.zero) {
      _endTime = DateTime.now().add(duration);
      _timer = Timer(duration, () async {
        try {
          await onExpire();
        } catch (_) {
          // The callback (the player) logs its own failures. A timer callback
          // must never throw an unhandled async error.
        }
      });
    }
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _endTime = null;
    _endOfSong = false;
    _endOfQueue = false;
  }
}
