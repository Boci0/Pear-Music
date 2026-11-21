import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A tiny rotating log file for release builds.
///
/// Windows GUI apps have no console, so `debugPrint` output is invisible in
/// the wild. [DebugLog] mirrors every line into `<support>/peerm_debug.log`
/// (capped at ~512 KB, oldest half discarded on overflow) so post-transfer
/// user can share. Writes are fire-and-forget: logging must never block or
/// user can share. Writes are fire-and-forget: logging must never block or
/// crash the app.
class DebugLog {
  DebugLog._();

  static File? _file;
  static bool _initTried = false;
  static Future<void>? _initFuture;
  static Future<void>? _pending;
  static final List<String> _buffer = [];
  static final List<String> _writeQueue = [];
  static Timer? _flushTimer;
  static int _writtenBytes = 0;
  static const int _flushBatchLines = 32;
  static const Duration _flushDelay = Duration(milliseconds: 250);
  static final StreamController<String> _liveController = StreamController<String>.broadcast();
  static final List<String> _recentLogs = [];
  static const int _maxRecentLogs = 80;

  /// Stream of live diagnostic log lines.
  static Stream<String> get stream => _liveController.stream;

  /// In-memory ring buffer of recent diagnostic messages.
  static List<String> get recentLogs => List.unmodifiable(_recentLogs);

  /// Clears recent in-memory logs.
  static void clearRecent() {
    _recentLogs.clear();
  }

  /// Cap before rotation. On overflow the OLDEST half is dropped so recent
  /// evidence always survives.
  static const int _maxBytes = 512 * 1024;

  /// The newest half of a UTF-8 log, starting at a whole line. Decoding as
  /// UTF-8 keeps non-English titles intact across a rotation.
  @visibleForTesting
  static String newestHalf(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final half = text.length ~/ 2;
    final lineStart = text.indexOf('\n', half);
    return text.substring(lineStart < 0 ? half : lineStart + 1);
  }

  static File? get file => _file;

  /// Test hook: override the base directory instead of using path_provider.
  @visibleForTesting
  static Directory? debugBaseDirectory;

  /// Test hook: forget the file, the init flag and buffered lines so a test
  /// can exercise the first-init path again.
  @visibleForTesting
  static void resetForTesting() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _writeQueue.clear();
    _writtenBytes = 0;
    _file = null;
    _initTried = false;
    _initFuture = null;
    _pending = null;
    _buffer.clear();
    _recentLogs.clear();
  }

  /// Flushes any queued log lines to disk so tests can inspect the log file.
  @visibleForTesting
  static Future<void> flushForTesting() async {
    if (_initFuture != null) {
      await _initFuture;
    }
    _flushTimer?.cancel();
    _flushTimer = null;
    final f = _file;
    if (f != null && _writeQueue.isNotEmpty) {
      _flushNow(f);
    }
    if (_pending != null) {
      await _pending;
    }
  }

  /// Writes the queued batch to [file] through the shared write chain and
  /// rotates once mid-session if the file crosses [_maxBytes].
  static void _flushNow(File file) {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_writeQueue.isEmpty) return;
    final batch = '${_writeQueue.join('\n')}\n';
    _writeQueue.clear();
    final out = _pending ?? Future<void>.value();
    _pending = out.then((_) async {
      try {
        await file.writeAsString(batch, mode: FileMode.append, flush: false);
        _writtenBytes += utf8.encode(batch).length;
        if (_writtenBytes > _maxBytes) {
          final rotated = newestHalf(await file.readAsBytes());
          await file.writeAsString(rotated, flush: false);
          _writtenBytes = utf8.encode(rotated).length;
        }
      } catch (_) {}
    });
  }

  /// Queues [formattedLine] for batched disk appending so bursts of log lines
  /// coalesce into one syscall instead of one open/append/close per line.
  static void _appendToFile(File file, String formattedLine) {
    _writeQueue.add(formattedLine);
    if (_writeQueue.length >= _flushBatchLines) {
      _flushNow(file);
      return;
    }
    _flushTimer ??= Timer(_flushDelay, () {
      _flushTimer = null;
      _flushNow(file);
    });
  }

  static void _ensureInit() {
    if (_initTried) return;
    _initTried = true;
    _initFuture = () async {
      try {
        final dir =
            debugBaseDirectory ?? await getApplicationSupportDirectory();
        final f = File(p.join(dir.path, 'peerm_debug.log'));
        if (await f.exists()) {
          _writtenBytes = await f.length();
          if (_writtenBytes > _maxBytes) {
            // Rotate: keep only the newest half.
            final rotated = newestHalf(await f.readAsBytes());
            await f.writeAsString(rotated);
            _writtenBytes = utf8.encode(rotated).length;
          }
        } else {
          _writtenBytes = 0;
        }
        _file = f;
        // Lines logged while the path was still being resolved are written
        // now, in order, instead of being dropped for the whole session.
        if (_buffer.isNotEmpty) {
          _writeQueue.addAll(_buffer);
          _buffer.clear();
          _flushNow(f);
        }
      } catch (_) {
        _file = null; // logging unavailable; silently drop lines
      }
    }();
    unawaited(_initFuture);
  }

  /// Whether lines are also printed to the system log (Android's logcat).
  static bool echoToSystemLog = Platform.isAndroid;

  /// Append one line. Safe to call from anywhere; failures are swallowed.
  ///
  /// [echo] also prints the line to the Android system log; the debugPrint
  /// hook in main() passes false because it prints the line itself.
  static void write(String line, {bool echo = true}) {
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${(now.millisecond ~/ 100)}';
    final formattedLine = '[$timeStr] $line';

    if (_recentLogs.length >= _maxRecentLogs) {
      _recentLogs.removeAt(0);
    }
    _recentLogs.add(formattedLine);
    // Android release builds keep the log file in private storage; mirroring
    // to logcat lets a connected computer read it over adb. Plain print, not
    // debugPrint: main() routes debugPrint into this method, so calling it
    // here would loop forever (and froze the app on launch).
    if (echo && echoToSystemLog) {
      // ignore: avoid_print
      print('[peerm] $line');
    }
    if (_liveController.hasListener) {
      _liveController.add(formattedLine);
    }

    _ensureInit();
    final f = _file;
    if (f == null) {
      // Not initialised yet (async): buffer briefly, drop if init fails.
      if (_buffer.length < 200) _buffer.add(formattedLine);
      return;
    }
    _appendToFile(f, formattedLine);
  }
}
