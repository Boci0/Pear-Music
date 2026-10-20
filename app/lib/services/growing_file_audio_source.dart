// StreamAudioSource is marked experimental in just_audio, but it has been
// stable across releases and is the supported way to feed bytes the app
// produces itself. If an upgrade changes it, this file is the only user.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:synchronized/synchronized.dart';

/// Plays an audio file while yt-dlp is still writing it.
///
/// Used on Android, where YouTube turns the phone's player away if it asks
/// for the stream link itself: only yt-dlp talks to YouTube, and playback
/// reads the bytes it has already written to the cache file. A read that
/// reaches the end of what is on disk waits for more instead of ending the
/// track, until [done] completes.
///
/// One file handle is kept open for the whole life of the source (see
/// [close]). yt-dlp may replace the file when it finishes (its m4a fixup
/// writes a remuxed copy and renames it over the original); the open handle
/// keeps reading the original bytes, so offsets the player already parsed
/// stay valid.
class GrowingFileAudioSource extends StreamAudioSource {
  GrowingFileAudioSource({
    required this.path,
    required this.done,
    this.expectedLength,
    this.contentType = 'audio/mp4',
    this.pollInterval = const Duration(milliseconds: 50),
    this.openTimeout = const Duration(seconds: 30),
    this.stallTimeout = const Duration(seconds: 20),
    super.tag,
  }) {
    done.then((_) => _finished = true, onError: (_) => _finished = true);
  }

  /// Where yt-dlp is writing the file.
  final String path;

  /// Completes when the download has ended, successfully or not.
  final Future<void> done;

  /// Full size of the file if known up front (YouTube reports it). Without
  /// it the player cannot seek until the download is done.
  final int? expectedLength;

  final String contentType;
  final Duration pollInterval;

  /// How long to wait for yt-dlp to create the file before giving up.
  final Duration openTimeout;

  /// How long to wait for new bytes before calling the download dead.
  ///
  /// Without this the read loops forever: a connection that drops mid-song
  /// ends neither the download nor the file, so the player waits on a stream
  /// that will never advance and the song hangs on loading with no error and
  /// no way out but stopping it by hand. Giving up hands the failure to the
  /// player, which reports it and can retry.
  final Duration stallTimeout;

  bool _finished = false;
  bool _closed = false;
  RandomAccessFile? _file;
  Future<RandomAccessFile>? _opening;
  final Lock _lock = Lock();

  Future<RandomAccessFile> _open() => _opening ??= () async {
        final deadline = DateTime.now().add(openTimeout);
        final file = File(path);
        while (!await file.exists()) {
          if (_closed) throw StateError('source closed');
          if (_finished) {
            // One last look: the download may have finished between checks.
            if (await file.exists()) break;
            throw FileSystemException('download ended without a file', path);
          }
          if (DateTime.now().isAfter(deadline)) {
            throw FileSystemException('timed out waiting for the file', path);
          }
          await Future<void>.delayed(pollInterval);
        }
        final opened = await file.open();
        if (_closed) {
          // close() ran while the handle was being opened and saw no handle
          // to release: release it here instead of leaking it (on Windows an
          // open handle also keeps the file from being deleted or renamed).
          try {
            await opened.close();
          } catch (_) {}
          throw StateError('source closed');
        }
        return _file = opened;
      }();

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final file = await _open();
    final total = expectedLength;
    final from = start ?? 0;
    final to = end ?? total;
    return StreamAudioResponse(
      rangeRequestsSupported: total != null,
      sourceLength: total,
      contentLength: to == null ? null : to - from,
      offset: start == null ? null : from,
      contentType: contentType,
      stream: _read(file, from, to),
    );
  }

  Stream<List<int>> _read(RandomAccessFile file, int from, int? to) async* {
    const chunkSize = 64 * 1024;
    var position = from;
    var lastProgress = DateTime.now();
    while (!_closed && (to == null || position < to)) {
      // Check "finished" before measuring, so bytes written just before the
      // download ended are still read on this pass.
      final finished = _finished;
      final available = await _lock.synchronized(file.length);
      if (position < available) {
        var count = available - position;
        if (to != null && to - position < count) count = to - position;
        if (count > chunkSize) count = chunkSize;
        final bytes = await _lock.synchronized(() async {
          await file.setPosition(position);
          return file.read(count);
        });
        if (bytes.isEmpty) {
          await Future<void>.delayed(pollInterval);
          continue;
        }
        position += bytes.length;
        lastProgress = DateTime.now();
        yield bytes;
      } else if (finished) {
        break;
      } else {
        // Nothing new on disk. A download that stopped without ending (the
        // connection dropped mid-song) never produces another byte, so the
        // read must fail instead of waiting forever.
        if (DateTime.now().difference(lastProgress) > stallTimeout) {
          throw StateError(
            'the download stopped for '
            '${stallTimeout.inSeconds} s at $position bytes',
          );
        }
        await Future<void>.delayed(pollInterval);
      }
    }
  }

  /// Releases the file handle. Call once the player has moved on.
  Future<void> close() async {
    _closed = true;
    final file = _file;
    _file = null;
    if (file != null) {
      await _lock.synchronized(() async {
        try {
          await file.close();
        } catch (_) {}
      });
    }
  }
}
