import 'dart:convert';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'library_service.dart';
import 'youtube_service.dart';

/// Structured result for a single self-test item.
class SelfTestResult {
  final String name;
  final bool passed;
  final int durationMs;
  final String? error;
  final Map<String, dynamic>? details;

  SelfTestResult({
    required this.name,
    required this.passed,
    required this.durationMs,
    this.error,
    this.details,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'passed': passed,
        'duration_ms': durationMs,
        if (error != null) 'error': error,
        if (details != null) 'details': details,
      };
}

/// Automated in-app diagnostics suite for validating the real desktop executable.
class SelfTestService {
  static const String flag = '--self-test';

  static Future<void> run(List<String> args) async {
    final swTotal = Stopwatch()..start();
    final results = <SelfTestResult>[];

    void log(String msg) {
      // ignore: avoid_print
      print('[self-test] $msg');
    }

    log('Starting automated desktop self-test suite...');

    // 1. Directory and storage verification
    results.add(await _testStorage(log));

    // 2. yt-dlp binary presence and process tree verification
    results.add(await _testYtDlp(log));

    // 3. Audio subsystem initialization and player lifecycle
    results.add(await _testAudioSubsystem(log));

    // 4. Library service and index integrity
    results.add(await _testLibrary(log));

    swTotal.stop();

    final allPassed = results.every((r) => r.passed);
    final summary = {
      'timestamp': DateTime.now().toIso8601String(),
      'platform': Platform.operatingSystem,
      'total_duration_ms': swTotal.elapsedMilliseconds,
      'all_passed': allPassed,
      'results': results.map((r) => r.toJson()).toList(),
    };

    // Write structured report to application support directory
    try {
      final supportDir = await getApplicationSupportDirectory();
      final reportFile = File(p.join(supportDir.path, 'self_test_report.json'));
      await reportFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(summary),
      );
      log('Report saved to: ${reportFile.path}');
    } catch (e) {
      log('Failed to save report file: $e');
    }

    log('Self-test complete. ${allPassed ? "ALL TESTS PASSED" : "TESTS FAILED"}.');
    exit(allPassed ? 0 : 1);
  }

  static Future<SelfTestResult> _testStorage(void Function(String) log) async {
    final sw = Stopwatch()..start();
    try {
      final supportDir = await getApplicationSupportDirectory();
      final libraryDir = Directory(p.join(supportDir.path, 'library'));
      final incomingDir = Directory(p.join(libraryDir.path, '_incoming'));

      await libraryDir.create(recursive: true);
      await incomingDir.create(recursive: true);

      // Verify file read/write
      final testFile = File(p.join(libraryDir.path, '.self_test_probe'));
      await testFile.writeAsString('probe_${DateTime.now().millisecondsSinceEpoch}');
      final readBack = await testFile.readAsString();
      await testFile.delete();

      sw.stop();
      log('Storage check passed (${sw.elapsedMilliseconds} ms)');
      return SelfTestResult(
        name: 'storage_health',
        passed: readBack.startsWith('probe_'),
        durationMs: sw.elapsedMilliseconds,
        details: {
          'support_path': supportDir.path,
          'library_path': libraryDir.path,
        },
      );
    } catch (e) {
      sw.stop();
      log('Storage check failed: $e');
      return SelfTestResult(
        name: 'storage_health',
        passed: false,
        durationMs: sw.elapsedMilliseconds,
        error: e.toString(),
      );
    }
  }

  static Future<SelfTestResult> _testYtDlp(void Function(String) log) async {
    final sw = Stopwatch()..start();
    try {
      final bin = await YoutubeService.ytDlpPath();
      if (bin == null) {
        sw.stop();
        log('yt-dlp binary not found on desktop');
        return SelfTestResult(
          name: 'ytdlp_probe',
          passed: false,
          durationMs: sw.elapsedMilliseconds,
          error: 'yt-dlp executable not located on system path or app folders.',
        );
      }

      final proc = await Process.start(bin, ['--version']);
      final outBuf = StringBuffer();
      final sub = proc.stdout.transform(utf8.decoder).listen(outBuf.write);
      final exitCode = await proc.exitCode.timeout(const Duration(seconds: 5));
      await sub.cancel();

      sw.stop();
      final version = outBuf.toString().trim();
      final passed = exitCode == 0 && version.isNotEmpty;
      log('yt-dlp probe passed: version $version (${sw.elapsedMilliseconds} ms)');
      return SelfTestResult(
        name: 'ytdlp_probe',
        passed: passed,
        durationMs: sw.elapsedMilliseconds,
        details: {
          'binary_path': bin,
          'version': version,
          'exit_code': exitCode,
        },
      );
    } catch (e) {
      sw.stop();
      log('yt-dlp probe failed: $e');
      return SelfTestResult(
        name: 'ytdlp_probe',
        passed: false,
        durationMs: sw.elapsedMilliseconds,
        error: e.toString(),
      );
    }
  }

  static Future<SelfTestResult> _testAudioSubsystem(void Function(String) log) async {
    final sw = Stopwatch()..start();
    AudioPlayer? player;
    try {
      JustAudioMediaKit.ensureInitialized();
      player = AudioPlayer();
      final state = player.playerState;
      sw.stop();
      log('Audio subsystem check passed: state ${state.processingState} (${sw.elapsedMilliseconds} ms)');
      return SelfTestResult(
        name: 'audio_subsystem',
        passed: true,
        durationMs: sw.elapsedMilliseconds,
        details: {
          'processing_state': state.processingState.name,
          'playing': state.playing,
        },
      );
    } catch (e) {
      sw.stop();
      log('Audio subsystem check failed: $e');
      return SelfTestResult(
        name: 'audio_subsystem',
        passed: false,
        durationMs: sw.elapsedMilliseconds,
        error: e.toString(),
      );
    } finally {
      await player?.dispose();
    }
  }

  static Future<SelfTestResult> _testLibrary(void Function(String) log) async {
    final sw = Stopwatch()..start();
    try {
      final library = LibraryService();
      await library.init();
      final songCount = library.songs.length;
      final playlistCount = library.playlists.length;
      sw.stop();
      log('Library check passed: $songCount songs, $playlistCount playlists (${sw.elapsedMilliseconds} ms)');
      return SelfTestResult(
        name: 'library_integrity',
        passed: true,
        durationMs: sw.elapsedMilliseconds,
        details: {
          'song_count': songCount,
          'playlist_count': playlistCount,
        },
      );
    } catch (e) {
      sw.stop();
      log('Library check failed: $e');
      return SelfTestResult(
        name: 'library_integrity',
        passed: false,
        durationMs: sw.elapsedMilliseconds,
        error: e.toString(),
      );
    }
  }
}
