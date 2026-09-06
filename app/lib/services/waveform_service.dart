import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'debug_log.dart';
import 'youtube_service.dart';

/// Service responsible for extracting, caching, and serving pre-computed
/// audio waveform amplitude envelopes for playback visualization.
///
/// Strictly guarantees that no duplicate processes or parallel extraction
/// workers are spawned.
class WaveformService {
  static final WaveformService instance = WaveformService._internal();
  WaveformService._internal();

  static const int barCount = 128;
  static const int _maxMemoryEntries = 64;

  final LinkedHashMap<String, List<double>> _memoryCache = LinkedHashMap();
  final Map<String, Future<List<double>?>> _inFlight = {};

  // Sequential task queue to ensure strictly one extraction process runs at a time
  final Queue<_WaveformTask> _queue = Queue();
  bool _isWorkerActive = false;

  Directory? _cacheDir;
  String? _ffmpegPath;
  bool _ffmpegChecked = false;

  /// Locates ffmpeg executable on Windows or POSIX environments.
  Future<String?> _findFFmpeg() async {
    if (_ffmpegChecked) return _ffmpegPath;
    _ffmpegChecked = true;
    if (kIsWeb) return null;

    try {
      if (Platform.isWindows) {
        final r = await Process.run('where.exe', ['ffmpeg']).timeout(const Duration(seconds: 2));
        if (r.exitCode == 0) {
          final lines = r.stdout.toString().split(RegExp(r'[\r\n]+'));
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isNotEmpty && File(trimmed).existsSync()) {
              _ffmpegPath = trimmed;
              return trimmed;
            }
          }
        }
        final local = Platform.environment['LOCALAPPDATA'];
        if (local != null) {
          final wingetDir = Directory(p.join(local, 'Microsoft', 'WinGet', 'Packages'));
          if (wingetDir.existsSync()) {
            for (final entity in wingetDir.listSync(recursive: true, followLinks: false)) {
              if (entity is File && p.basename(entity.path).toLowerCase() == 'ffmpeg.exe') {
                _ffmpegPath = entity.path;
                return entity.path;
              }
            }
          }
        }
      } else {
        final r = await Process.run('which', ['ffmpeg']).timeout(const Duration(seconds: 2));
        if (r.exitCode == 0) {
          final path = r.stdout.toString().trim();
          if (path.isNotEmpty && File(path).existsSync()) {
            _ffmpegPath = path;
            return path;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Directory where binary .wf waveform files are persisted.
  Future<Directory> getCacheDirectory() async {
    if (_cacheDir != null) return _cacheDir!;
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(supportDir.path, 'waveform_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  /// Synchronous memory cache lookup. Returns null if not yet resolved.
  List<double>? getCachedSync(String songId) {
    return _memoryCache[songId];
  }

  /// Retrieves the waveform for [songId].
  ///
  /// Checks memory cache -> disk cache -> single background worker extraction.
  /// Deduplicates concurrent requests for the identical [songId].
  Future<List<double>?> getWaveform(String songId, File? audioFile) {
    // 1. Memory cache hit
    final inMemory = _memoryCache[songId];
    if (inMemory != null) {
      _memoryCache.remove(songId);
      _memoryCache[songId] = inMemory;
      return Future.value(inMemory);
    }

    // 2. In-flight request deduplication
    final existingFuture = _inFlight[songId];
    if (existingFuture != null) {
      return existingFuture;
    }

    final completer = Completer<List<double>?>();
    final future = completer.future;
    _inFlight[songId] = future;

    _resolveWaveform(songId, audioFile).then((result) {
      if (result != null) {
        _memoryCache[songId] = result;
        while (_memoryCache.length > _maxMemoryEntries) {
          _memoryCache.remove(_memoryCache.keys.first);
        }
      }
      completer.complete(result);
    }).catchError((e) {
      DebugLog.write('[waveform] Error resolving waveform for $songId: $e');
      completer.complete(null);
    }).whenComplete(() {
      _inFlight.remove(songId);
    });

    return future;
  }

  Future<List<double>?> _resolveWaveform(String songId, File? audioFile) async {
    // Check disk cache first
    final dir = await getCacheDirectory();
    final diskFile = File(p.join(dir.path, '$songId.wf'));
    if (await diskFile.exists()) {
      try {
        final bytes = await diskFile.readAsBytes();
        if (bytes.length >= barCount) {
          return bytes.sublist(0, barCount).map((b) => (b / 255.0).clamp(0.0, 1.0)).toList();
        }
      } catch (_) {}
    }

    if (audioFile == null || !await audioFile.exists()) {
      return null;
    }

    // Enqueue extraction into sequential single worker
    return await _enqueue(songId, audioFile, diskFile);
  }

  Future<List<double>?> _enqueue(String songId, File audioFile, File diskFile) {
    final completer = Completer<List<double>?>();
    _queue.add(_WaveformTask(
      songId: songId,
      audioFile: audioFile,
      diskFile: diskFile,
      completer: completer,
    ));
    _processQueue();
    return completer.future;
  }

  void _processQueue() async {
    if (_isWorkerActive || _queue.isEmpty) return;
    _isWorkerActive = true;

    final task = _queue.removeFirst();
    try {
      final peaks = await _extractPeaks(task.audioFile);
      if (peaks != null && peaks.length == barCount) {
        // Write to disk cache
        try {
          final bytes = Uint8List.fromList(
            peaks.map((p) => (p * 255.0).round().clamp(0, 255)).toList(),
          );
          await task.diskFile.writeAsBytes(bytes, flush: true);
        } catch (_) {}
        task.completer.complete(peaks);
      } else {
        task.completer.complete(null);
      }
    } catch (e) {
      DebugLog.write('[waveform] Extraction failed for ${task.songId}: $e');
      task.completer.complete(null);
    } finally {
      _isWorkerActive = false;
      if (_queue.isNotEmpty) {
        _processQueue();
      }
    }
  }

  /// Extracts amplitude peaks using ffmpeg if present, otherwise falling back
  /// to pure Dart frame sampling. Guarantees process cleanup and zero zombie tasks.
  Future<List<double>?> _extractPeaks(File audioFile) async {
    final ffmpeg = await _findFFmpeg();
    if (ffmpeg != null) {
      final peaks = await _extractWithFFmpeg(ffmpeg, audioFile);
      if (peaks != null && peaks.isNotEmpty) {
        return peaks;
      }
    }

    // Pure Dart container fallback (zero external processes)
    return await compute(_extractPureDartSync, audioFile.path);
  }

  Future<List<double>?> _extractWithFFmpeg(String bin, File audioFile) async {
    Process? proc;
    try {
      final args = [
        '-v', 'error',
        '-i', audioFile.path,
        '-ac', '1',
        '-filter:a', 'aresample=1000',
        '-f', 's16le',
        '-',
      ];
      proc = await Process.start(bin, args);
      final rawBytes = <int>[];
      final sub = proc.stdout.listen((data) => rawBytes.addAll(data));

      int exitCode;
      try {
        exitCode = await proc.exitCode.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        YoutubeService.killProcessTree(proc.pid);
        rethrow;
      } finally {
        await sub.cancel();
      }

      if (exitCode == 0 && rawBytes.length >= 2) {
        final buffer = Uint8List.fromList(rawBytes).buffer;
        final samples = Int16List.view(buffer);
        if (samples.isNotEmpty) {
          return _downsamplePeaks(samples, barCount);
        }
      }
    } catch (e) {
      DebugLog.write('[waveform] ffmpeg probe error: $e');
    } finally {
      if (proc != null) {
        YoutubeService.killProcessTree(proc.pid);
      }
    }
    return null;
  }

  static List<double> _downsamplePeaks(Int16List samples, int count) {
    final result = List<double>.filled(count, 0.0);
    final chunkSize = (samples.length / count).floor();
    if (chunkSize <= 0) return result;

    double maxVal = 1.0;
    for (int i = 0; i < count; i++) {
      final start = i * chunkSize;
      final end = (i == count - 1) ? samples.length : (start + chunkSize);
      double sumSquares = 0.0;
      int n = 0;
      for (int j = start; j < end; j += 2) {
        final v = samples[j];
        sumSquares += v * v;
        n++;
      }
      final rms = n > 0 ? math.sqrt(sumSquares / n) : 0.0;
      result[i] = rms;
      if (rms > maxVal) maxVal = rms;
    }

    // Normalize from 0.0 to 1.0 with subtle dynamic compression for visual balance
    for (int i = 0; i < count; i++) {
      final norm = (result[i] / maxVal).clamp(0.0, 1.0);
      result[i] = math.pow(norm, 0.75).toDouble();
    }
    return result;
  }

  /// Pure Dart fallback executed in a background isolate.
  /// Samples audio file byte distribution across time slices without external processes.
  static List<double>? _extractPureDartSync(String filePath) {
    try {
      final file = File(filePath);
      final len = file.lengthSync();
      if (len < 1024) return null;

      final result = List<double>.filled(barCount, 0.0);
      final raf = file.openSync(mode: FileMode.read);
      try {
        final step = (len / barCount).floor();
        const sampleWindow = 256;
        double maxEnergy = 1.0;

        for (int i = 0; i < barCount; i++) {
          final pos = (i * step).clamp(0, len - sampleWindow);
          raf.setPositionSync(pos);
          final chunk = raf.readSync(sampleWindow);

          double variance = 0.0;
          if (chunk.isNotEmpty) {
            double mean = 0.0;
            for (final b in chunk) {
              mean += b;
            }
            mean /= chunk.length;
            for (final b in chunk) {
              final diff = b - mean;
              variance += diff * diff;
            }
            variance = math.sqrt(variance / chunk.length);
          }
          result[i] = variance;
          if (variance > maxEnergy) maxEnergy = variance;
        }

        for (int i = 0; i < barCount; i++) {
          final norm = (result[i] / maxEnergy).clamp(0.0, 1.0);
          result[i] = math.pow(norm, 0.8).toDouble();
        }
        return result;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return null;
    }
  }

  /// Clears in-memory cache to reclaim RAM on app backgrounding.
  void clearMemoryCache() {
    _memoryCache.clear();
  }

  @visibleForTesting
  void setCacheDirectoryForTesting(Directory? dir) {
    _cacheDir = dir;
  }

  @visibleForTesting
  void putInMemoryCacheForTesting(String songId, List<double> peaks) {
    _memoryCache[songId] = peaks;
  }

  @visibleForTesting
  static List<double> downsamplePeaksForTesting(Int16List samples, int count) =>
      _downsamplePeaks(samples, count);

  @visibleForTesting
  static List<double>? extractPureDartSyncForTesting(String filePath) =>
      _extractPureDartSync(filePath);
}

class _WaveformTask {
  final String songId;
  final File audioFile;
  final File diskFile;
  final Completer<List<double>?> completer;

  _WaveformTask({
    required this.songId,
    required this.audioFile,
    required this.diskFile,
    required this.completer,
  });
}
