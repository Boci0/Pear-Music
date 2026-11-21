// StreamAudioSource is marked experimental in just_audio, but it has been
// stable across releases and is the supported way to feed bytes the app
// produces itself.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

/// Holds an audio track's bytes in RAM while it downloads (and while it sits in
/// the ephemeral RAM cache before being promoted or flushed to disk).
///
/// Chunks are stored as defensive copies as they arrive so a caller reusing its
/// read buffer cannot corrupt stored audio, and readers waiting past the
/// current end of the buffer wake up as soon as more bytes arrive or the
/// transfer ends.
class RamAudioBuffer {
  RamAudioBuffer({
    required this.videoId,
    required this.ext,
    this.expectedLength,
  });

  final String videoId;
  final String ext;
  final int? expectedLength;

  final List<Uint8List> _chunks = [];
  final List<int> _chunkOffsets = [];
  int _length = 0;
  bool _done = false;
  String? _error;
  Completer<void>? _waiter;

  int get length => _length;
  bool get isFinished => _done;
  bool get isComplete => _done && _error == null;
  String? get error => _error;

  void _wakeReaders() {
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  /// Appends [chunk] to the buffer and wakes any waiting readers.
  void append(List<int> chunk) {
    if (_done || chunk.isEmpty) return;
    _chunkOffsets.add(_length);
    _chunks.add(Uint8List.fromList(chunk));
    _length += chunk.length;
    _wakeReaders();
  }

  /// Marks the buffer complete so readers stop at EOF once caught up.
  void markComplete() {
    if (_done) return;
    _done = true;
    _wakeReaders();
  }

  /// Marks the buffer failed, drops partial chunks, and wakes waiting readers.
  void markFailed(String error) {
    if (_done) return;
    _done = true;
    _error = error;
    _chunks.clear();
    _chunkOffsets.clear();
    _length = 0;
    _wakeReaders();
  }

  /// Reads up to [count] bytes starting at [offset] without allocating the
  /// whole buffer.
  Uint8List readSlice(int offset, int count) {
    if (offset < 0 || offset >= _length || count <= 0 || _chunks.isEmpty) {
      return Uint8List(0);
    }
    final want = math.min(count, _length - offset);
    final out = Uint8List(want);
    // Binary-search the chunk whose start offset <= [offset].
    var lo = 0;
    var hi = _chunkOffsets.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_chunkOffsets[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    var written = 0;
    for (var i = lo; i < _chunks.length && written < want; i++) {
      final chunk = _chunks[i];
      final chunkStart = _chunkOffsets[i];
      final copyStart = offset > chunkStart ? offset - chunkStart : 0;
      final remaining = want - written;
      final copyCount = math.min(remaining, chunk.length - copyStart);
      if (copyCount > 0) {
        out.setRange(written, written + copyCount, chunk, copyStart);
        written += copyCount;
      }
    }
    return out;
  }

  /// Waits until the buffer grows past [currentOffset], finishes, or times out.
  Future<void> waitForMore(int currentOffset, Duration timeout) async {
    while (!_done && _length <= currentOffset) {
      final waiter = _waiter ??= Completer<void>();
      await waiter.future.timeout(timeout);
    }
  }

  /// Returns a contiguous copy of all buffered bytes.
  Uint8List toBytes() {
    if (_chunks.isEmpty || _length == 0) return Uint8List(0);
    final out = Uint8List(_length);
    var pos = 0;
    for (final chunk in _chunks) {
      out.setRange(pos, pos + chunk.length, chunk);
      pos += chunk.length;
    }
    return out;
  }
}

/// Plays audio directly from an in-memory [RamAudioBuffer], either while it is
/// still growing or once it is complete.
class RamAudioSource extends StreamAudioSource {
  RamAudioSource({
    required this.buffer,
    this.contentType = 'audio/mp4',
    this.stallTimeout = const Duration(seconds: 20),
    super.tag,
  });

  final RamAudioBuffer buffer;
  final String contentType;
  final Duration stallTimeout;

  bool _closed = false;
  final Completer<void> _closedSignal = Completer<void>();

  /// Marks this source closed so any open stream ends immediately.
  void close() {
    _closed = true;
    if (!_closedSignal.isCompleted) _closedSignal.complete();
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    if (_closed) throw StateError('source closed');
    final total = buffer.isComplete ? buffer.length : buffer.expectedLength;
    final from = start ?? 0;
    final rawTo = end ?? total;
    final to = (rawTo != null && total != null && rawTo > total)
        ? total
        : rawTo;
    if (buffer.isFinished &&
        !buffer.isComplete &&
        to != null &&
        from < to &&
        from >= buffer.length) {
      throw StateError('download failed: ${buffer.error}');
    }
    return StreamAudioResponse(
      rangeRequestsSupported: total != null,
      sourceLength: total,
      contentLength: to == null ? null : to - from,
      offset: (start == null || to == null) ? null : from,
      contentType: contentType,
      stream: _read(from, to),
    );
  }

  Stream<List<int>> _read(int from, int? to) async* {
    const chunkSize = 64 * 1024;
    var position = from;
    while (!_closed && (to == null || position < to)) {
      if (position < buffer.length) {
        var count = buffer.length - position;
        if (to != null && to - position < count) count = to - position;
        if (count > chunkSize) count = chunkSize;
        final slice = buffer.readSlice(position, count);
        if (slice.isEmpty) continue;
        position += slice.length;
        yield slice;
      } else if (buffer.isFinished) {
        if (!buffer.isComplete && (to == null || position < to)) {
          throw StateError('download failed: ${buffer.error}');
        }
        break;
      } else {
        try {
          final waiter = buffer.waitForMore(position, stallTimeout);
          unawaited(waiter.catchError((Object _) {}));
          await Future.any<void>([waiter, _closedSignal.future]);
        } on TimeoutException {
          throw StateError(
            'download stalled for ${stallTimeout.inSeconds}s at $position bytes',
          );
        }
      }
    }
  }
}
