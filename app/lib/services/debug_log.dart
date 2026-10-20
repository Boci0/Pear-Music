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
  static Future<void>? _pending;
  static final List<String> _buffer = [];
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
    _file = null;
    _initTried = false;
    _pending = null;
    _buffer.clear();
    _recentLogs.clear();
  }

  /// Appends [formattedLine] to [file] through the shared write chain, so a
  /// burst of log lines is written in order and no caller waits on the disk.
  static void _appendToFile(File file, String formattedLine) {
    final out = _pending ?? Future<void>.value();
    _pending = out.then((_) async {
      try {
        await file.writeAsString('$formattedLine\n',
            mode: FileMode.append, flush: false);
      } catch (_) {}
    });
  }

  static void _ensureInit() {
    if (_initTried) return;
    _initTried = true;
    unawaited(() async {
      try {
        final dir =
            debugBaseDirectory ?? await getApplicationSupportDirectory();
        final f = File(p.join(dir.path, 'peerm_debug.log'));
        if (await f.exists() && await f.length() > _maxBytes) {
          // Rotate: keep only the newest half.
          await f.writeAsString(newestHalf(await f.readAsBytes()));
        }
        _file = f;
        // Lines logged while the path was still being resolved are written
        // now, in order, instead of being dropped for the whole session.
        if (_buffer.isNotEmpty) {
          for (final buffered in _buffer) {
            _appendToFile(f, buffered);
          }
          _buffer.clear();
        }
      } catch (_) {
        _file = null; // logging unavailable; silently drop lines
      }
    }());
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
