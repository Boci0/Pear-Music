import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import 'artwork_service.dart';
import 'library_service.dart';
import 'ytdlp_manifest.dart';

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

class _YtDlpSource {
  const _YtDlpSource(this.base, {required this.requireManifest});
  final String base;
  final bool requireManifest;
}

class _ResolvedYtDlp {
  const _ResolvedYtDlp(this.base, this.sha256, this.version);
  final String base;
  final String sha256;

  /// yt-dlp version from a verified manifest; null for checksum-only sources.
  final String? version;
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

  static String? _cachedYtDlpPath;

  /// Locate a yt-dlp (or youtube-dl) executable. Checks PATH first, then the
  /// well-known winget shim folder (`%LOCALAPPDATA%\Microsoft\WinGet\Links`),
  /// and finally the app's local bin folder.
  ///
  /// The result is memoised: every stream fetch asks for the binary, and the
  /// lookup can spawn `where.exe` / `which`. A cached path is only reused
  /// while the file still exists, and a miss is never cached, so installing
  /// yt-dlp while the app runs is still picked up on the next fetch.
  static Future<String?> ytDlpPath({bool refresh = false}) async {
    if (!refresh) {
      final cached = _cachedYtDlpPath;
      if (cached != null && File(cached).existsSync()) return cached;
    }
    final resolved = await _detectYtDlpPath();
    _cachedYtDlpPath = resolved;
    return resolved;
  }

  static Future<String?> _detectYtDlpPath() async {
    if (kIsWeb) return null;
    try {
      // Bundled binary directly alongside the executable (e.g. deployed standalone package)
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final bundledBin = File(p.join(exeDir, Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp'));
      if (bundledBin.existsSync()) return bundledBin.path;

      if (Platform.isWindows) {
        final r = await Process.run('where.exe', ['yt-dlp']);
        if (r.exitCode == 0) {
          final lines = r.stdout.toString().split(RegExp(r'[\r\n]+'));
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isNotEmpty && File(trimmed).existsSync()) return trimmed;
          }
        }
        // winget installs a shim here even when PATH in this process is stale.
        final local = Platform.environment['LOCALAPPDATA'];
        if (local != null) {
          final shim = File('$local\\Microsoft\\WinGet\\Links\\yt-dlp.exe');
          if (shim.existsSync()) return shim.path;
          for (final pyVer in ['Python312', 'Python311', 'Python310', 'Python313']) {
            final pyBin = File('$local\\Programs\\Python\\$pyVer\\Scripts\\yt-dlp.exe');
            if (pyBin.existsSync()) return pyBin.path;
          }
        }
        final userProfile = Platform.environment['USERPROFILE'];
        if (userProfile != null) {
          final scoopBin = File('$userProfile\\scoop\\shims\\yt-dlp.exe');
          if (scoopBin.existsSync()) return scoopBin.path;
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

  static const _ytDlpUpstreamBase =
      'https://github.com/yt-dlp/yt-dlp/releases/latest/download';

  /// Our own signed copies of yt-dlp, refreshed by the `ytdlp-mirror` workflow
  /// under a fixed release tag on two hosts. They keep installs and updates
  /// working if upstream disappears or one host goes away.
  static const _ytDlpMirrorBase =
      'https://github.com/Boci0/Pear-Music/releases/download/yt-dlp-mirror';
  static const _ytDlpCodebergBase =
      'https://codeberg.org/Boci0/Pear-Music/releases/download/yt-dlp-mirror';

  /// Ordered download sources for yt-dlp: user overrides, then our signed
  /// mirrors (plus any extra sources a verified manifest listed), then
  /// upstream. Overrides come from the `PEARMUSIC_YTDLP_BASE_URL` environment
  /// variable, then one URL per line in `ytdlp_sources.txt` in the app support
  /// folder (blank lines and `#` comments are ignored).
  ///
  /// A base serves the asset (`yt-dlp.exe`, `yt-dlp_linux`, `yt-dlp_macos`)
  /// plus either a signed `manifest.json` / `manifest.json.sig` pair or a plain
  /// `SHA2-256SUMS`. Our own mirrors must serve the signed manifest.
  static Future<List<_YtDlpSource>> _ytDlpSources() async {
    final overrides = <String>[];
    final env = Platform.environment['PEARMUSIC_YTDLP_BASE_URL'];
    if (env != null) overrides.add(env);
    var extra = const <String>[];
    try {
      final supportDir = await getApplicationSupportDirectory();
      final file = File(p.join(supportDir.path, 'ytdlp_sources.txt'));
      if (await file.exists()) overrides.addAll(await file.readAsLines());
      extra = (await _readCachedManifest())?.sources ?? const [];
    } catch (_) {}
    final custom = mergeYtDlpSources(overrides, const []);
    final signed = mergeYtDlpSources(
      const [],
      [_ytDlpMirrorBase, _ytDlpCodebergBase, ...extra],
    ).where((b) => !custom.contains(b));
    return [
      for (final b in custom) _YtDlpSource(b, requireManifest: false),
      for (final b in signed) _YtDlpSource(b, requireManifest: true),
      const _YtDlpSource(_ytDlpUpstreamBase, requireManifest: false),
    ];
  }

  /// Cleans [overrides] (trims, drops blanks, comments and non-https entries,
  /// strips trailing slashes) and appends [defaults], removing duplicates.
  @visibleForTesting
  static List<String> mergeYtDlpSources(
    Iterable<String> overrides,
    Iterable<String> defaults,
  ) {
    final out = <String>[];
    for (final raw in [...overrides, ...defaults]) {
      var s = raw.trim();
      if (s.isEmpty || s.startsWith('#')) continue;
      if (!s.startsWith('https://')) continue;
      while (s.endsWith('/')) {
        s = s.substring(0, s.length - 1);
      }
      if (!out.contains(s)) out.add(s);
    }
    return out;
  }

  /// Finds [assetName]'s SHA-256 in the text of a release `SHA2-256SUMS` file
  /// (`<hex>  <name>` per line). Returns null when the asset is not listed.
  @visibleForTesting
  static String? parseSha256Sums(String sums, String assetName) {
    for (final line in const LineSplitter().convert(sums)) {
      final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(\S+)\s*$').firstMatch(line.trim());
      if (m != null && m.group(2) == assetName) return m.group(1)!.toLowerCase();
    }
    return null;
  }

  static const _manifestCacheName = 'ytdlp_manifest.json';

  static Future<YtDlpManifest?> _readCachedManifest() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final m = File(p.join(dir.path, _manifestCacheName));
      final s = File(p.join(dir.path, '$_manifestCacheName.sig'));
      if (!await m.exists() || !await s.exists()) return null;
      return YtDlpManifest.parseVerified(
        await m.readAsBytes(),
        Uint8List.fromList(base64.decode((await s.readAsString()).trim())),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _cacheManifest(Uint8List manifest, String sigText) async {
    try {
      final dir = await getApplicationSupportDirectory();
      await File(p.join(dir.path, _manifestCacheName)).writeAsBytes(manifest);
      await File(p.join(dir.path, '$_manifestCacheName.sig'))
          .writeAsString(sigText);
    } catch (_) {}
  }

  /// GETs [url] and returns its body, or null on a non-200 or any error.
  static Future<Uint8List?> _getBytes(
    HttpClient client,
    String url, {
    int maxBytes = 1 << 20,
  }) async {
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'PearMusic-App');
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final out = BytesBuilder(copy: false);
      await for (final chunk
          in response.timeout(const Duration(seconds: 20))) {
        out.add(chunk);
        if (out.length > maxBytes) return null;
      }
      return out.takeBytes();
    } catch (_) {
      return null;
    }
  }

  /// Works out what to download from [source] and the hash it must have.
  ///
  /// A manifest, when the host serves one, must carry a valid signature: a
  /// present-but-bad manifest rejects the source outright instead of falling
  /// back to the unsigned checksums. Hosts without a manifest are only
  /// accepted when the source does not require one (upstream, user overrides).
  static Future<_ResolvedYtDlp?> _resolveYtDlp(
    HttpClient client,
    _YtDlpSource source,
    String assetName,
  ) async {
    final manifestBytes =
        await _getBytes(client, '${source.base}/manifest.json');
    if (manifestBytes != null) {
      final sigBytes =
          await _getBytes(client, '${source.base}/manifest.json.sig');
      final sigText = sigBytes == null
          ? ''
          : utf8.decode(sigBytes, allowMalformed: true).trim();
      YtDlpManifest? manifest;
      try {
        manifest = YtDlpManifest.parseVerified(
            manifestBytes, Uint8List.fromList(base64.decode(sigText)));
      } catch (_) {}
      final asset = manifest?.assets[assetName];
      if (manifest == null || asset == null) {
        debugPrint('[pearmusic] yt-dlp manifest from ${source.base} invalid or missing $assetName');
        return null;
      }
      unawaited(_cacheManifest(manifestBytes, sigText));
      return _ResolvedYtDlp(source.base, asset.sha256, manifest.ytDlpVersion);
    }
    if (source.requireManifest) return null;
    final sums = await _getBytes(client, '${source.base}/SHA2-256SUMS');
    if (sums == null) return null;
    final hash =
        parseSha256Sums(utf8.decode(sums, allowMalformed: true), assetName);
    return hash == null ? null : _ResolvedYtDlp(source.base, hash, null);
  }

  /// Downloads [assetName] from [resolved] into [tempFile] and checks size and
  /// SHA-256. Deletes [tempFile] and returns false on any failure.
  static Future<bool> _downloadYtDlp(
    HttpClient client,
    _ResolvedYtDlp resolved,
    String assetName,
    File tempFile,
  ) async {
    try {
      final request =
          await client.getUrl(Uri.parse('${resolved.base}/$assetName'));
      request.headers.set('User-Agent', 'PearMusic-App');
      request.headers.set('Accept', 'application/octet-stream');
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        await response.drain<void>();
        debugPrint('[pearmusic] yt-dlp source ${resolved.base} answered ${response.statusCode}');
        return false;
      }
      final sink = tempFile.openWrite();
      try {
        // No data for 30 seconds is a dead connection, not a slow one.
        await sink.addStream(response.timeout(const Duration(seconds: 30)));
      } finally {
        await sink.close();
      }
      final len = await tempFile.length();
      final actual = (await sha256.bind(tempFile.openRead()).first).toString();
      if (len > 1000000 && actual == resolved.sha256) return true;
      debugPrint('[pearmusic] yt-dlp from ${resolved.base} failed size or checksum verification ($len bytes)');
    } catch (e) {
      debugPrint('[pearmusic] yt-dlp download from ${resolved.base} failed: $e');
    }
    try {
      if (await tempFile.exists()) await tempFile.delete();
    } catch (_) {}
    return false;
  }

  static String get _ytDlpAssetName => Platform.isWindows
      ? 'yt-dlp.exe'
      : (Platform.isMacOS ? 'yt-dlp_macos' : 'yt-dlp_linux');

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

      final assetName = _ytDlpAssetName;

      // Every stream fetch waits on this download, so a stalled connection
      // must fail rather than leave playback spinning forever.
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        for (final source in await _ytDlpSources()) {
          final resolved = await _resolveYtDlp(client, source, assetName);
          if (resolved == null) {
            debugPrint('[pearmusic] yt-dlp source ${source.base} unusable, trying next');
            continue;
          }
          if (!await _downloadYtDlp(client, resolved, assetName, tempFile)) {
            continue;
          }
          if (!Platform.isWindows) {
            await Process.run('chmod', ['+x', tempFile.path]);
          }
          if (await targetFile.exists()) await targetFile.delete();
          await tempFile.rename(targetFile.path);
          _downloadingYtDlp!.complete(targetFile.path);
          return targetFile.path;
        }
      } finally {
        client.close(force: true);
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

  /// Forcibly terminates a process and any descendant processes it spawned.
  /// On Windows, invokes `taskkill /F /T /PID <pid>` to prevent zombie child
  /// processes; on other platforms, calls `Process.killPid`.
  static void killProcessTree(int pid) {
    try {
      if (!kIsWeb && Platform.isWindows) {
        unawaited(Process.run('taskkill', ['/F', '/T', '/PID', '$pid']));
      } else {
        Process.killPid(pid);
      }
    } catch (_) {}
  }

  /// Sweeps temporary directory for lingering `peerm-ytdlp-*` folders from previous
  /// crashes or ungraceful exits older than 2 hours.
  static Future<void> cleanupOrphanedTempDirs() async {
    if (kIsWeb) return;
    try {
      final tempDir = Directory.systemTemp;
      if (!await tempDir.exists()) return;
      final threshold = DateTime.now().subtract(const Duration(hours: 2));
      await for (final entity in tempDir.list(followLinks: false)) {
        if (entity is Directory && p.basename(entity.path).startsWith('peerm-')) {
          try {
            final stat = await entity.stat();
            if (stat.modified.isBefore(threshold)) {
              await entity.delete(recursive: true);
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Runs a once-per-session update of the desktop yt-dlp on Windows so it
  /// keeps up with YouTube changes.
  ///
  /// The primary path reads the signed manifest from our mirrors and swaps in
  /// a newer, signature-verified binary. Only when no signed manifest can be
  /// reached does it fall back to upstream's own `yt-dlp -U`.
  ///
  /// The returned future completes when the update attempt is over (or after
  /// 60 s), which matters for callers that must not touch the binary while the
  /// updater is replacing it, such as the pre-booted spare.
  static Future<void> checkDesktopYtDlpUpdate() async {
    if (kIsWeb || !Platform.isWindows || _updateChecked) return;
    _updateChecked = true;
    try {
      final bin = await ytDlpPath();
      if (bin == null) return;
      var manifestSeen = false;
      try {
        manifestSeen = await _updateFromManifest(bin)
            .timeout(const Duration(seconds: 60));
      } catch (e) {
        debugPrint('[pearmusic] Desktop yt-dlp manifest update error: $e');
      }
      if (manifestSeen) return;
      try {
        final r = await Process.run(bin, ['-U'])
            .timeout(const Duration(seconds: 15));
        debugPrint('[pearmusic] Desktop yt-dlp -U exit code: ${r.exitCode}');
      } catch (e) {
        debugPrint('[pearmusic] Desktop yt-dlp update check error: $e');
      }
    } catch (_) {}
  }

  /// Updates [bin] from the first source that serves a verified manifest.
  /// Returns true when such a manifest was reached (whether or not a newer
  /// build existed), false when none could be, so the caller can fall back.
  static Future<bool> _updateFromManifest(String bin) async {
    final assetName = _ytDlpAssetName;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      for (final source in await _ytDlpSources()) {
        final resolved = await _resolveYtDlp(client, source, assetName);
        final latest = resolved?.version;
        if (resolved == null || latest == null) continue;

        final current = (await Process.run(bin, ['--version'])
                .timeout(const Duration(seconds: 10)))
            .stdout
            .toString()
            .trim();
        if (!YtDlpManifest.isNewerVersion(latest, current)) {
          debugPrint('[pearmusic] yt-dlp $current is current (latest $latest)');
          return true;
        }

        final fresh = File('$bin.new');
        if (await fresh.exists()) await fresh.delete();
        if (!await _downloadYtDlp(client, resolved, assetName, fresh)) {
          continue;
        }
        // A running exe can be renamed but not overwritten on Windows.
        final old = File('$bin.old');
        try {
          if (await old.exists()) await old.delete();
        } catch (_) {}
        await File(bin).rename(old.path);
        try {
          await fresh.rename(bin);
        } catch (e) {
          await old.rename(bin);
          rethrow;
        }
        debugPrint('[pearmusic] yt-dlp updated $current -> $latest from ${resolved.base}');
        return true;
      }
    } finally {
      client.close(force: true);
    }
    return false;
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
    String? artist,
    YoutubeStatusCallback? onStatus,
    YoutubeProgressCallback? onProgress,
    DownloadCancellation? cancel,
  }) async {
    var bin = await ytDlpPath();
    bin ??= await ensureYtDlpAvailable(onStatus: onStatus);
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

      Future<int> runDownloadWithArgs(List<String> extraArgs) async {
        final isAndroid = !kIsWeb && Platform.isAndroid;
        final formatArg = isAndroid
            ? '140/bestaudio[ext=m4a]/bestaudio[abr<=128]/bestaudio/best'
            : 'bestaudio[acodec=opus][abr<=160]/141/bestaudio[ext=m4a]/bestaudio/best';
        final args = [
          '-f', formatArg,
          '--extractor-args', 'youtube:player_client=android,web',
          '--newline',
          '--no-playlist',
          '--no-part',
          '--no-mtime',
          '--write-thumbnail',
          '--no-check-certificates',
          '--concurrent-fragments', '4',
          ...extraArgs,
          '-o', outTemplate,
          url,
        ];
        final proc = await Process.start(finalBin, args);
        if (cancel != null) {
          unawaited(cancel.whenCancelled.then((_) {
            killProcessTree(proc.pid);
          }));
        }
        final outBuf = StringBuffer();
        final errBuf = StringBuffer();
        // Progress lines ([download] NN% of XMiB) arrive on stdout; stderr
        // only gets warnings and errors, so feed both streams to the parser.
        final outSub = proc.stdout.transform(utf8.decoder).listen((chunk) {
          outBuf.write(chunk);
          _parseYtDlpProgress(chunk, onProgress);
        });
        final errSub = proc.stderr.transform(utf8.decoder).listen((chunk) {
          errBuf.write(chunk);
          _parseYtDlpProgress(chunk, onProgress);
        });
        int exit;
        try {
          exit = await proc.exitCode.timeout(const Duration(minutes: 6));
        } on TimeoutException {
          killProcessTree(proc.pid);
          rethrow;
        } finally {
          await outSub.cancel();
          await errSub.cancel();
        }
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
          artwork =
              await downscaleToBase64Async(await File(thumbPath).readAsBytes());
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
        artist: artist,
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
          artwork =
              await downscaleToBase64Async(await File(thumbPath).readAsBytes());
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

  /// Center-crop + downscale an image to a square JPEG and return it as
  /// base64. Bounded to [size] (default 640px) at high quality to preserve
  /// sharpness on desktop and high-DPI displays.
  static String? downscaleToBase64(
    List<int> bytes, {
    int size = 640,
    int quality = 90,
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
      final targetSide = math.min(side, size);
      final resized = (crop.width > targetSide || crop.height > targetSide)
          ? img.copyResize(crop, width: targetSide, height: targetSide)
          : crop;
      return base64Encode(img.encodeJpg(resized, quality: quality));
    } catch (_) {
      return null;
    }
  }

  /// Async wrapper around [downscaleToBase64]: the decode, crop and encode
  /// run on a worker isolate so bulk imports keep the main isolate free (no
  /// multi-megabyte pixel buffers blocking frames).
  static Future<String?> downscaleToBase64Async(
    List<int> bytes, {
    int size = 640,
    int quality = 90,
  }) {
    return compute(
      _downscaleEntry,
      (Uint8List.fromList(bytes), size, quality),
    );
  }

  /// Robust HTTP fetch of thumbnail bytes, downscaling and converting to persistent base64 JPEG.
  /// Applies [ArtworkService.optimizeArtworkUrl] to fetch crisp high-resolution sources.
  static Future<String?> downloadArtworkAsBase64(
    String? artworkUrl, {
    String? videoId,
    int size = 640,
    int quality = 90,
  }) async {
    if (artworkUrl != null && !artworkUrl.startsWith('http')) {
      return artworkUrl; // Already base64 encoded
    }

    final effectiveUrl = (artworkUrl != null && artworkUrl.isNotEmpty)
        ? ArtworkService.optimizeArtworkUrl(artworkUrl)
        : null;

    final urls = <String>[
      if (effectiveUrl != null && effectiveUrl.isNotEmpty) effectiveUrl,
      if (artworkUrl != null && artworkUrl.isNotEmpty && artworkUrl != effectiveUrl) artworkUrl,
      if (videoId != null && videoId.isNotEmpty) ...[
        'https://i.ytimg.com/vi/$videoId/sddefault.jpg',
        'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
        'https://i.ytimg.com/vi/$videoId/mqdefault.jpg',
      ],
    ];

    for (final u in urls) {
      HttpClient? client;
      try {
        client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..autoUncompress = true;
        final req = await client.getUrl(Uri.parse(u));
        req.followRedirects = true;
        req.maxRedirects = 5;
        final resp = await req.close().timeout(const Duration(seconds: 5));
        if (resp.statusCode == 200) {
          final bytes = await resp
              .fold<List<int>>([], (p, e) => p..addAll(e))
              .timeout(const Duration(seconds: 5));
          if (bytes.isNotEmpty) {
            final downscaled =
                await downscaleToBase64Async(bytes, size: size, quality: quality);
            if (downscaled != null && downscaled.isNotEmpty) {
              return downscaled;
            }
          }
        }
      } catch (_) {
      } finally {
        client?.close(force: true);
      }
    }
    return null;
  }
}

/// Worker-isolate entry for [YoutubeService.downscaleToBase64Async].
String? _downscaleEntry((Uint8List, int, int) args) {
  final (bytes, size, quality) = args;
  return YoutubeService.downscaleToBase64(bytes, size: size, quality: quality);
}
