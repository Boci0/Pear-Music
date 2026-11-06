import 'dart:async';

/// Thins a playback-position stream for read-outs that only show where the
/// song is (progress lines, time labels).
///
/// just_audio's position stream adds a value on every player event on top of
/// its own timer, and on desktop the engine reports events about 15 times a
/// second while playing. Each value rebuilds the read-out and makes the
/// window redraw, for movement nobody can see on a thin line or a seconds
/// label. This passes a position on only when its whole second changes, or on
/// a seek (back, a new song, or forward by more than [jump]), so labels
/// change the moment the second does and seeks show at once. Repeats
/// (paused) are dropped.
///
/// The result is a broadcast stream that listens to [source] only while it
/// has listeners itself.
Stream<Duration> positionSeconds(
  Stream<Duration> source, {
  Duration jump = const Duration(milliseconds: 1500),
}) {
  StreamSubscription<Duration>? subscription;
  Duration? last;
  late final StreamController<Duration> out;
  out = StreamController<Duration>.broadcast(
    onListen: () {
      subscription = source.listen(
        (position) {
          final previous = last;
          if (previous == null ||
              position < previous ||
              position - previous > jump ||
              position.inSeconds != previous.inSeconds) {
            last = position;
            out.add(position);
          }
        },
        onError: out.addError,
      );
    },
    onCancel: () {
      subscription?.cancel();
      subscription = null;
      last = null;
    },
  );
  return out.stream;
}
