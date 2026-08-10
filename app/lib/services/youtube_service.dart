import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../models/song.dart';
import 'library_service.dart';

/// Live status text for the "Add from link" dialog.
typedef YoutubeStatusCallback = void Function(String status);

/// Live download progress (bytes downloaded, total bytes) for the link dialog.
/// `totalBytes` may be 0 when the source does not report a size (show an
/// indeterminate bar in that case).
typedef YoutubeProgressCallback = void Function(
  int downloadedBytes,
  int totalBytes,
);

/// Mutable abort flag threaded through a rip so the UI can cancel an in-flight
/// download (e.g. the "Add from link" dialog's Cancel button).
class DownloadCancellation {
  bool _cancelled = false;
  final Completer<void> _done = Completer<void>();
  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_done.isCompleted) _done.complete();
  }
}

/// Marker thrown when a rip was cancelled by the user (not a real failure).
class DownloadCancelledException implements Exception {
  @override
  String toString() => 'Download cancelled.';
}

/// Rips audio from a link using yt-dlp — the ONLY downloader.
///
///  * **Desktop** ([scrapeAndAddWithYtDlp]): runs an installed yt-dlp binary
///    via [Process].
///  * **Android** ([scrapeAndAddWithEmbeddedYtDlp]): uses the yt-dlp bundled
///    inside the APK (via `youtubedl-android`, the same engine Seal bundles)
///    through the `peerm/ytdlp` platform channel.
///
/// Works for YouTube and Spotify links (yt-dlp resolves Spotify to a YouTube
/// source itself). The audio downloads straight to the device that runs this
/// service; the caller then broadcasts the resulting song to paired peers. The
/// artwork is downscaled and embedded in the [Song] as base64, so it rides
/// inside the existing manifest/file_meta JSON.
///
/// The former built-in downloader (youtube_explode) and the Piped-proxy engine
/// were removed (2026-08-10): the built-in got YouTube-IP-rate-limited on this
/// network and the public Piped fleet is dead, so yt-dlp is the reliable
/// single path.
class YoutubeService {
  /// Locate a yt-dlp (or youtube-dl) executable. Checks PATH first, then the
  /// well-known winget shim folder (`%LOCALAPPDATA%\Microsoft\WinGet\Links`) so
  /// detection works even when the app was launched from a process with a
  /// stale PATH. Returns the resolved path, or null if not installed. Only
  /// meaningful on desktop; the phone uses the bundled copy instead.
  @visibleForTesting
  static Future<String?> ytDlpPath() async {
    if (kIsWeb) return null;
    try {
      if (Platform.isWindows) {
        final r = await Process.run('where.exe', ['yt-dlp']);
        if (r.exitCode == 0) {
          final first =
              r.stdout.toString().trim().split(RegExp(r'\s+')).first;
          if (first.isNotEmpty && File(first).existsSync()) return first;
        }
        // winget installs a shim here even when PATH in this process is stale.
        final local = Platform.environment['LOCALAPPDATA'];
        if (local != null) {
          final shim = File('$local\\Microsoft\\WinGet\\Links\\yt-dlp.exe');
          if (shim.existsSync()) return shim.path;
        }
      } else {
        final r = await Process.run('which', ['yt-dlp']);
        if (r.exitCode == 0) {
          final out = r.stdout.toString().trim();
          if (out.isNotEmpty && File(out).existsSync()) return out;
        }
      }
    } catch (_) {}
    return null;
  }

  /// True when a yt-dlp binary is reachable on the desktop.
  static Future<bool> isYtDlpAvailable() async => await ytDlpPath() != null;

  /// True when the app can rip with the **bundled** yt-dlp (Android only).
  static bool get isEmbeddedYtDlpSupported => !kIsWeb && Platform.isAndroid;

  /// Rip [url] with an installed yt-dlp binary (desktop). Downloads the best
  /// audio-only stream (m4a preferred; no ffmpeg/conversion needed). Works for
  /// YouTube and Spotify links (yt-dlp resolves Spotify itself).
  Future<Song?> scrapeAndAddWithYtDlp(
    LibraryService library,
    String url, {
    String? preferredArtwork,
    YoutubeStatusCallback? onStatus,
    YoutubeProgressCallback? onProgress,
    DownloadCancellation? cancel,
  }) async {
    final bin = await ytDlpPath();
    if (bin == null) {
      throw Exception('yt-dlp is not installed on this device.');
    }
    Directory? tempDir;
    try {
      onStatus?.call('Starting yt-dlp…');
      tempDir = await Directory.systemTemp.createTemp('peerm-ytdlp-');
      final outTemplate = '${tempDir.path}${Platform.pathSeparator}'
          '%(title).80B [%(id)s].%(ext)s';
      final args = [
        '-f', 'bestaudio[ext=m4a]/bestaudio',
        // NOTE: no --extractor-args — forcing a player client (e.g. android)
        // fails with "Requested format is not available". The default client
        // works with a current yt-dlp.
        '--newline',
        '--no-playlist',
        '--no-part',
        '--no-mtime',
        '--write-thumbnail',
        '-o', outTemplate,
        url,
      ];
      final proc = await Process.start(bin, args);
      if (cancel != null) {
        unawaited(cancel.whenCancelled.then((_) {
          try {
            proc.kill();
          } catch (_) {}
        }));
      }
      final outBuf = StringBuffer();
      final errBuf = StringBuffer();
      final outSub = proc.stdout.transform(utf8.decoder).listen(outBuf.write);
      final errSub = proc.stderr.transform(utf8.decoder).listen((chunk) {
        errBuf.write(chunk);
        _parseYtDlpProgress(chunk, onProgress);
      });
      final exit = await proc.exitCode.timeout(const Duration(minutes: 6));
      await outSub.cancel();
      await errSub.cancel();
      if (cancel?.isCancelled ?? false) {
        throw DownloadCancelledException();
      }
      if (exit != 0) {
        final lines = errBuf.toString().trim().split('\n');
        final tail = lines.length > 4
            ? lines.sublist(lines.length - 4).join('\n')
            : lines.join('\n');
        throw Exception('yt-dlp failed (exit $exit): $tail');
      }

      onStatus?.call('Finding audio file…');
      File? audioFile;
      String? thumbPath;
      for (final f in tempDir.listSync().whereType<File>()) {
        final ext = p.extension(f.path).toLowerCase();
        if (_audioExts.contains(ext)) {
          audioFile ??= f;
        } else if (_imgExts.contains(ext)) {
          thumbPath ??= f.path;
        }
      }
      if (audioFile == null) {
        throw Exception('yt-dlp did not produce an audio file.');
      }

      String? artwork = preferredArtwork;
      if (artwork == null && thumbPath != null) {
        try {
          artwork = downscaleToBase64(await File(thumbPath).readAsBytes());
        } catch (_) {
          // Artwork optional — fall back to the gradient.
        }
      }

      onStatus?.call('Adding to library…');
      final base = p.basenameWithoutExtension(audioFile.path);
      final title = base.replaceFirst(RegExp(r'\s+\[[^\]]+\]$'), '');
      return await library.addScrapedFile(
        audioFile,
        title: title,
        artwork: artwork,
      );
    } on TimeoutException {
      throw Exception('yt-dlp timed out. Try again later.');
    } finally {
      try {
        await tempDir?.delete(recursive: true);
      } catch (_) {}
    }
  }

  static const _audioExts = {
    '.m4a', '.mp4', '.webm', '.opus', '.mka', '.ogg', '.aac', '.mp3', '.flac',
    '.wav',
  };
  static const _imgExts = {'.jpg', '.jpeg', '.png', '.webp'};

  /// Rip [url] with the yt-dlp engine bundled inside the APK (Android, via
  /// `youtubedl-android`). This is the phone's reliable downloader: yt-dlp
  /// authenticates with cookies, so it is far less likely to be throttled, and
  /// it needs no external binary or public proxy instance. Works for YouTube
  /// and Spotify links.
  Future<Song?> scrapeAndAddWithEmbeddedYtDlp(
    LibraryService library,
    String url, {
    String? preferredArtwork,
    YoutubeStatusCallback? onStatus,
    YoutubeProgressCallback? onProgress,
    DownloadCancellation? cancel,
  }) async {
    if (!isEmbeddedYtDlpSupported) {
      throw Exception('Embedded yt-dlp is only available on Android.');
    }
    const channel = MethodChannel('peerm/ytdlp');
    const events = EventChannel('peerm/ytdlp/progress');

    Directory? tempDir;
    StreamSubscription<dynamic>? progressSub;
    try {
      onStatus?.call('Starting yt-dlp…');
      // The first init refreshes the bundled yt-dlp from the stable channel
      // (~15 MB), so allow up to 2 minutes for it.
      final version = await channel
          .invokeMethod<String>('init')
          .timeout(const Duration(seconds: 120));
      debugPrint('[pearmusic] embedded yt-dlp ready: $version');

      tempDir = await Directory.systemTemp.createTemp('peerm-ytdlp-');
      final processId = 'peerm-dl-${DateTime.now().millisecondsSinceEpoch}';

      // Progress lines stream in on the events channel; parse the
      // `[download] NN% of XXMiB` lines into the byte-based callback the link
      // dialog already understands.
      progressSub = events.receiveBroadcastStream().listen((event) {
        final line = (event is Map)
            ? (event['line'] as String? ?? '')
            : event.toString();
        _parseYtDlpProgress(line, onProgress);
      });

      if (cancel != null) {
        unawaited(cancel.whenCancelled.then((_) async {
          try {
            await channel.invokeMethod('cancel', {'processId': processId});
          } catch (_) {}
        }));
      }

      try {
        await channel
            .invokeMethod(
              'download',
              {
                'url': url,
                'outputDir': tempDir.path,
                'processId': processId,
              },
            )
            .timeout(const Duration(minutes: 7));
      } on PlatformException catch (e) {
        if (cancel?.isCancelled ?? false) {
          throw DownloadCancelledException();
        }
        debugPrint(
            '[pearmusic] embedded yt-dlp download error: ${e.code}: ${e.message}');
        throw Exception(e.message ?? 'yt-dlp failed.');
      }
      if (cancel?.isCancelled ?? false) {
        throw DownloadCancelledException();
      }

      onStatus?.call('Finding audio file…');
      File? audioFile;
      String? thumbPath;
      for (final f in tempDir.listSync().whereType<File>()) {
        final ext = p.extension(f.path).toLowerCase();
        if (_audioExts.contains(ext)) {
          audioFile ??= f;
        } else if (_imgExts.contains(ext)) {
          thumbPath ??= f.path;
        }
      }
      if (audioFile == null) {
        debugPrint('[pearmusic] no audio file in ${tempDir.path}: '
            '${tempDir.listSync().map((e) => p.basename(e.path)).join(', ')}');
        throw Exception('yt-dlp did not produce an audio file.');
      }

      String? artwork = preferredArtwork;
      if (artwork == null && thumbPath != null) {
        try {
          artwork = downscaleToBase64(await File(thumbPath).readAsBytes());
        } catch (_) {
          // Artwork optional — fall back to the gradient.
        }
      }

      onStatus?.call('Adding to library…');
      final base = p.basenameWithoutExtension(audioFile.path);
      final title = base.replaceFirst(RegExp(r'\s+\[[^\]]+\]$'), '');
      return await library.addScrapedFile(
        audioFile,
        title: title,
        artwork: artwork,
      );
    } on TimeoutException {
      throw Exception('yt-dlp timed out. Try again later.');
    } finally {
      await progressSub?.cancel();
      try {
        await tempDir?.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Parse yt-dlp's `[download] 12.3% of 3.42MiB …` progress lines into the
  /// byte-based [YoutubeProgressCallback] the dialog already understands.
  @visibleForTesting
  void parseYtDlpProgressForTest(String chunk, YoutubeProgressCallback? cb) =>
      _parseYtDlpProgress(chunk, cb);

  void _parseYtDlpProgress(
    String chunk,
    YoutubeProgressCallback? onProgress,
  ) {
    if (onProgress == null) return;
    final m = RegExp(
      r'\[download\]\s+(\d+(?:\.\d+)?)%\s+of\s+~?\s*([\d.]+)([KMG]i?B)',
    ).firstMatch(chunk);
    if (m == null) return;
    final pct = double.tryParse(m.group(1)!) ?? 0;
    final size = double.tryParse(m.group(2)!) ?? 0;
    final mult = switch (m.group(3)!) {
      'KiB' => 1024,
      'MiB' => 1024 * 1024,
      'GiB' => 1024 * 1024 * 1024,
      'kB' => 1000,
      'MB' => 1000 * 1000,
      'GB' => 1000 * 1000 * 1000,
      _ => 1,
    };
    final total = (size * mult).round();
    final downloaded = (pct / 100 * total).round();
    onProgress(downloaded, total);
  }

  /// Center-crop + downscale an image to a small square JPEG and return it as
  /// base64 (keeps the sync manifest small). Returns null if the bytes are not
  /// a decodable image.
  static String? downscaleToBase64(
    List<int> bytes, {
    int size = 256,
    int quality = 80,
  }) {
    try {
      final decoded = img.decodeImage(Uint8List.fromList(bytes));
      if (decoded == null) return null;
      final side =
          decoded.width < decoded.height ? decoded.width : decoded.height;
      final crop = img.copyCrop(
        decoded,
        x: (decoded.width - side) ~/ 2,
        y: (decoded.height - side) ~/ 2,
        width: side,
        height: side,
      );
      final resized = img.copyResize(crop, width: size, height: size);
      return base64Encode(img.encodeJpg(resized, quality: quality));
    } catch (_) {
      return null;
    }
  }
}
