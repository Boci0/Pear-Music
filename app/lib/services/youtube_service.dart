import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
  static Future<File> _getLocalYtDlpFile() async {
    final supportDir = await getApplicationSupportDirectory();
    final binDir = Directory(p.join(supportDir.path, 'bin'));
    if (!await binDir.exists()) {
      await binDir.create(recursive: true);
    }
    return File(p.join(binDir.path, Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp'));
  }

  /// Locate a yt-dlp (or youtube-dl) executable. Checks PATH first, then the
  /// well-known winget shim folder (`%LOCALAPPDATA%\Microsoft\WinGet\Links`),
  /// and finally the app's local bin folder.
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

      // Check app-local fallback binary
      final localBin = await _getLocalYtDlpFile();
      if (await localBin.exists() && await localBin.length() > 0) {
        return localBin.path;
      }
    } catch (_) {}
    return null;
  }

  static bool _updateChecked = false;
  static Completer<String?>? _downloadingYtDlp;

  /// Ensures yt-dlp binary is available on desktop, automatically downloading
  /// the official binary to app storage if not found anywhere on the system.
  static Future<String?> ensureYtDlpAvailable({
    YoutubeStatusCallback? onStatus,
  }) async {
    final existing = await ytDlpPath();
    if (existing != null) return existing;

    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return null;
    }

    if (_downloadingYtDlp != null) {
      return await _downloadingYtDlp!.future;
    }

    _downloadingYtDlp = Completer<String?>();
    try {
      onStatus?.call('Downloading yt-dlp dependencies…');
      final targetFile = await _getLocalYtDlpFile();
      final tempFile = File('${targetFile.path}.tmp');
      if (await tempFile.exists()) await tempFile.delete();

      final downloadUrl = Platform.isWindows
          ? 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
          : (Platform.isMacOS
              ? 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos'
              : 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux');

      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(downloadUrl));
      final response = await request.close();

      if (response.statusCode == 200) {
        final sink = tempFile.openWrite();
        await response.pipe(sink);
        await sink.close();

        if (await tempFile.length() > 0) {
          if (!Platform.isWindows) {
            await Process.run('chmod', ['+x', tempFile.path]);
          }
          if (await targetFile.exists()) await targetFile.delete();
          await tempFile.rename(targetFile.path);
          _downloadingYtDlp!.complete(targetFile.path);
          return targetFile.path;
        }
      }
      _downloadingYtDlp!.complete(null);
      return null;
    } catch (e) {
      debugPrint('[pearmusic] Failed to download yt-dlp automatically: $e');
      _downloadingYtDlp!.complete(null);
      return null;
    } finally {
      _downloadingYtDlp = null;
    }
  }

  /// Runs a background, non-blocking `yt-dlp -U` once per session on Windows
  /// so the desktop binary stays updated against YouTube cipher changes.
  static Future<void> checkDesktopYtDlpUpdate() async {
    if (kIsWeb || !Platform.isWindows || _updateChecked) return;
    _updateChecked = true;
    try {
      final bin = await ytDlpPath();
      if (bin != null) {
        unawaited(
          Process.run(bin, ['-U']).then((r) {
            debugPrint('[pearmusic] Desktop yt-dlp -U exit code: ${r.exitCode}');
          }).catchError((e) {
            debugPrint('[pearmusic] Desktop yt-dlp update check error: $e');
          }),
        );
      }
    } catch (_) {}
  }

  /// True when a yt-dlp binary is reachable on the desktop.
  static Future<bool> isYtDlpAvailable() async => await ytDlpPath() != null;

  /// True when the app can rip with the **bundled** yt-dlp (Android only).
  static bool get isEmbeddedYtDlpSupported => !kIsWeb && Platform.isAndroid;

  /// Locate `aria2c` on PATH (Windows: `where.exe`, others: `which`). Returns
  /// null when missing or when the check itself fails — aria2c is an optional
  /// accelerator, never a requirement.
  @visibleForTesting
  static Future<String?> aria2cPath() async {
    if (kIsWeb) return null;
    try {
      if (Platform.isWindows) {
        final r = await Process.run('where.exe', ['aria2c']);
        if (r.exitCode == 0) {
          final first =
              r.stdout.toString().trim().split(RegExp(r'\s+')).first;
          if (first.isNotEmpty && File(first).existsSync()) return first;
        }
      } else {
        final r = await Process.run('which', ['aria2c']);
        if (r.exitCode == 0) {
          final out = r.stdout.toString().trim();
          if (out.isNotEmpty && File(out).existsSync()) return out;
        }
      }
    } catch (_) {}
    return null;
  }

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
    var bin = await ytDlpPath();
    if (bin == null) {
      bin = await ensureYtDlpAvailable(onStatus: onStatus);
    }
    if (bin == null) {
      throw Exception(
        'yt-dlp could not be found or downloaded. Please check your internet connection.',
      );
    }
    final finalBin = bin;
    Directory? tempDir;
    try {
      onStatus?.call('Starting yt-dlp…');
      tempDir = await Directory.systemTemp.createTemp('peerm-ytdlp-');
      final outTemplate = '${tempDir.path}${Platform.pathSeparator}'
          '%(title).80B [%(id)s].%(ext)s';

      // Optional speed-up: delegate the actual download to aria2c (16
      // parallel connections) when it is installed. Missing aria2c must
      // never fail the rip — fall back to yt-dlp's native downloader.
      final aria2 = await aria2cPath();
      final downloaderArgs = (aria2 != null)
          ? <String>[
              '--downloader', 'aria2c',
              '--downloader-args', 'aria2c:-x 16 -s 16 -j 16',
            ]
          : const <String>[];
      if (aria2 != null) {
        debugPrint('[pearmusic] using aria2c downloader: $aria2');
      }

      Future<int> runDownloadWithArgs(List<String> extraArgs) async {
        final args = [
          '-f', 'bestaudio[ext=m4a]/bestaudio/best',
          '--extractor-args', 'youtube:player_client=android,web',
          '--newline',
          '--no-playlist',
          '--no-part',
          '--no-mtime',
          '--write-thumbnail',
          '--no-check-certificates',
          '--concurrent-fragments', '4',
          ...downloaderArgs,
          ...extraArgs,
          '-o', outTemplate,
          url,
        ];
        final proc = await Process.start(finalBin, args);
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
          debugPrint('[pearmusic] yt-dlp attempt failed (exit $exit): $tail');
        }
        return exit;
      }

      // Attempt 1: Client emulation (android, web, mweb) with audio stream support.
      int exitCode = await runDownloadWithArgs([
        '--extractor-args',
        'youtube:player_client=android,web,mweb',
      ]);

      // Attempt 2 (Fallback): Standard extraction if attempt 1 encountered an error.
      if (exitCode != 0 && !(cancel?.isCancelled ?? false)) {
        onStatus?.call('Retrying with fallback client…');
        exitCode = await runDownloadWithArgs([]);
      }

      if (exitCode != 0) {
        throw Exception('yt-dlp failed (exit $exitCode).');
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
      final title = sanitizeTitle(base);
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
      final title = sanitizeTitle(base);
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

  /// Clean up video title noise like `(Official Video)`, `[Official Music Video]`,
  /// `(Lyric Video)`, `(Audio)`, `(Official HD Video)`, `[Visualizer]`, etc.
  @visibleForTesting
  static String sanitizeTitle(String rawTitle) {
    var title = rawTitle.replaceFirst(RegExp(r'\s+\[[^\]]+\]$'), '').trim();
    title = title.replaceAll(
      RegExp(
        r'[\(\[]\s*(?:official\s+)?(?:music\s+)?(?:video|audio|lyric\s+video|lyrics|hd|4k|visualizer|mv|topic)\s*[\)\]]',
        caseSensitive: false,
      ),
      '',
    );
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    return title.isEmpty ? rawTitle : title;
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

  /// Robust HTTP fetch of thumbnail bytes, downscaling and converting to persistent base64 JPEG.
  static Future<String?> downloadArtworkAsBase64(
    String? artworkUrl, {
    String? videoId,
    int size = 256,
    int quality = 80,
  }) async {
    if (artworkUrl != null && !artworkUrl.startsWith('http')) {
      return artworkUrl; // Already base64 encoded
    }

    final urls = <String>[
      if (artworkUrl != null && artworkUrl.isNotEmpty) artworkUrl,
      if (videoId != null && videoId.isNotEmpty) ...[
        'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
        'https://i.ytimg.com/vi/$videoId/mqdefault.jpg',
      ],
    ];

    for (final u in urls) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..autoUncompress = true;
        final req = await client.getUrl(Uri.parse(u));
        req.followRedirects = true;
        req.maxRedirects = 5;
        final resp = await req.close().timeout(const Duration(seconds: 5));
        if (resp.statusCode == 200) {
          final bytes = await resp.fold<List<int>>([], (p, e) => p..addAll(e));
          client.close();
          if (bytes.isNotEmpty) {
            final downscaled = downscaleToBase64(bytes, size: size, quality: quality);
            if (downscaled != null && downscaled.isNotEmpty) {
              return downscaled;
            }
          }
        } else {
          client.close();
        }
      } catch (_) {}
    }
    return null;
  }
}
