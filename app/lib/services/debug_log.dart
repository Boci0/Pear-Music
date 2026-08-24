import 'dart:async';
import 'dart:io';

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

  /// Cap before rotation. On overflow the OLDEST half is dropped so recent
  /// evidence always survives.
  static const int _maxBytes = 512 * 1024;

  static File? get file => _file;

  static void _ensureInit() {
    if (_initTried) return;
    _initTried = true;
    unawaited(() async {
      try {
        final dir = await getApplicationSupportDirectory();
        final f = File(p.join(dir.path, 'peerm_debug.log'));
        if (await f.exists() && await f.length() > _maxBytes) {
          // Rotate: keep only the newest half.
          final bytes = await f.readAsBytes();
          final text = String.fromCharCodes(bytes);
          await f.writeAsString(text.substring(text.length ~/ 2));
        }
        _file = f;
      } catch (_) {
        _file = null; // logging unavailable; silently drop lines
      }
    }());
  }

  /// Append one line. Safe to call from anywhere; failures are swallowed.
  static void write(String line) {
    _ensureInit();
    final f = _file;
    if (f == null) {
      // Not initialised yet (async): buffer briefly, drop if init fails.
      if (_buffer.length < 200) _buffer.add(line);
      return;
    }
    final out = _pending ?? Future<void>.value();
    _pending = out.then((_) async {
      try {
        await f.writeAsString('$line\n',
            mode: FileMode.append, flush: false);
      } catch (_) {}
    });
  }
}
