import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'debug_log.dart';

/// Keeps one `yt-dlp` process pre-booted so a fetch does not pay the
/// PyInstaller startup (~2 s) on the critical path.
///
/// yt-dlp only starts working once its batch input reaches EOF, so the spare
/// is started early with `--batch-file -` and left waiting on stdin while the
/// app is idle. When a fetch needs it, the URL is written and stdin closed, so
/// the download starts immediately on an already-running process. A fresh
/// spare is booted again once the fetch finishes, off the critical path.
///
/// Measured on this machine with a local 1 MiB file: 2151 ms when spawning on
/// demand vs 1117 ms through a pre-booted spare.
class YtDlpPrewarmer {
  static final YtDlpPrewarmer instance = YtDlpPrewarmer._();

  YtDlpPrewarmer._();

  /// Whether pre-booting is used at all. Set `PEERM_YTDLP_PREWARM=0` to always
  /// spawn on demand (the original behaviour).
  static bool get enabled => _enabled ??= _readEnabled();

  static bool? _enabled;

  static bool _readEnabled() {
    try {
      final raw = Platform.environment['PEERM_YTDLP_PREWARM'];
      if (raw != null &&
          (raw == '0' || raw.toLowerCase() == 'false' || raw.toLowerCase() == 'off')) {
        return false;
      }
    } catch (_) {}
    return true;
  }

  @visibleForTesting
  static void setEnabledForTesting(bool? value) => _enabled = value;

  Process? _spare;
  String? _spareSignature;

  bool get hasSpare => _spare != null;
  int? get sparePid => _spare?.pid;

  /// The stdin-fed invocation: the URL arrives later on stdin, which is why
  /// `--batch-file -` is present and no URL is passed.
  static List<String> buildStdinArgs({
    required List<String> baseArgs,
    required String outputTemplate,
  }) {
    return [...baseArgs, '-o', outputTemplate, '--batch-file', '-'];
  }

  static String _signatureOf(
    String bin,
    List<String> baseArgs,
    String outputTemplate,
  ) =>
      '$bin\u0000${baseArgs.join('\u0000')}\u0000$outputTemplate';

  /// Boots a spare if none is alive. Safe to call often; failures are logged
  /// and never thrown, because a missing spare only means the next fetch pays
  /// the startup itself.
  Future<void> prewarm({
    required String bin,
    required List<String> baseArgs,
    required String outputTemplate,
  }) async {
    if (!enabled || kIsWeb || Platform.isAndroid) return;
    final signature = _signatureOf(bin, baseArgs, outputTemplate);
    if (_spare != null && _spareSignature == signature) return;
    killSpare();
    try {
      final process = await Process.start(
        bin,
        buildStdinArgs(baseArgs: baseArgs, outputTemplate: outputTemplate),
      );
      // The process only writes a short "Reading URLs from STDIN" note while
      // idle, so the pipes are left unsubscribed; the fetch attaches its own
      // listeners when it takes over.
      _spare = process;
      _spareSignature = signature;
      unawaited(process.exitCode.then((_) {
        if (identical(_spare, process)) {
          _spare = null;
          _spareSignature = null;
        }
      }).catchError((_) {}));
      DebugLog.write('[ytdlp-prewarm] spare booted (pid ${process.pid})');
    } catch (e) {
      DebugLog.write('[ytdlp-prewarm] could not boot a spare: $e');
    }
  }

  /// Takes the spare (or spawns a fresh process) and hands it the URL, with
  /// stdin closed so yt-dlp starts immediately. Returns null when no process
  /// could be started or fed.
  Future<Process?> startFetch({
    required String url,
    required String bin,
    required List<String> baseArgs,
    required String outputTemplate,
  }) async {
    final signature = _signatureOf(bin, baseArgs, outputTemplate);

    final spare = _spare;
    if (spare != null && _spareSignature == signature) {
      _spare = null;
      _spareSignature = null;
      if (await _feed(spare, url)) return spare;
      // The spare died before it could be used; fall through to a fresh one.
    } else if (spare != null) {
      // A spare for different arguments is of no use to this fetch.
      killSpare();
    }

    Process? fresh;
    try {
      fresh = await Process.start(
        bin,
        buildStdinArgs(baseArgs: baseArgs, outputTemplate: outputTemplate),
      );
    } catch (e) {
      DebugLog.write('[ytdlp-prewarm] spawn failed: $e');
      return null;
    }
    if (await _feed(fresh, url)) return fresh;
    try {
      fresh.kill();
    } catch (_) {}
    return null;
  }

  Future<bool> _feed(Process process, String url) async {
    try {
      process.stdin.writeln(url);
      await process.stdin.close();
      return true;
    } catch (e) {
      DebugLog.write('[ytdlp-prewarm] could not feed the process: $e');
      return false;
    }
  }

  /// Kills the idle spare (used when it is useless or the app is shutting
  /// down). Fetch processes are owned by the caller, not by this pool.
  void killSpare() {
    final spare = _spare;
    _spare = null;
    _spareSignature = null;
    if (spare == null) return;
    try {
      spare.kill();
    } catch (_) {}
  }
}
