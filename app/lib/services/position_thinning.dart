import 'dart:async';

/// Thins a playback-position stream for read-outs that only show where the
/// song is (progress lines, time labels).
///
/// just_audio's position stream adds a value on every player event on top of
/// its own timer, and on desktop the engine reports events about 15 times a
/// second while playing. Each value rebuilds the read-out and makes the
/// window redraw, which kept the GPU busy for movement nobody can see on a
/// thin line or a seconds label. This passes a position on only when it has
/// moved forward by at least [step] since the last one passed, or moved
/// backwards (a seek back, a new song), so playback still updates about four
/// times a second and seeks show at once. Repeats (paused) are dropped.
///
/// The result is a broadcast stream that listens to [source] only while it
/// has listeners itself.
Stream<Duration> thinPositions(
  Stream<Duration> source, {
  Duration step = const Duration(milliseconds: 250),
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
              position - previous >= step) {
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
