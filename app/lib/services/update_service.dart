import '../widgets/pear_sheet.dart';
import 'dart:async';
import 'dart:convert';
import '../theme/glass.dart';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_update_manifest.dart';
import 'backup_audio_engine.dart';
import 'debug_log.dart';
import 'http_client_factory.dart';

class UpdateInfo {
  final bool hasUpdate;
  final String currentVersion;
  final String latestVersion;
  final String releaseNotes;
  final String htmlUrl;
  final String? apkUrl;
  final String? setupUrl;
  final String? zipUrl;

  /// Expected SHA-256 digests keyed by asset filename, resolved from the
  /// release's `SHA256SUMS`/`checksums.txt` asset or the release body. Used to
  /// verify downloads before installing them.
  final Map<String, String> sha256ByName;

  /// True only when this came from a manifest whose Ed25519 signature checked
  /// out. Only verified updates are downloaded and installed in place; anything
  /// else just points the user at the release page.
  final bool verified;

  /// Every place each asset can be fetched from, keyed by file name, best
  /// first. Empty for unverified updates.
  final Map<String, List<String>> urlsByName;

  const UpdateInfo({
    required this.hasUpdate,
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    required this.htmlUrl,
    this.apkUrl,
    this.setupUrl,
    this.zipUrl,
    this.sha256ByName = const {},
    this.verified = false,
    this.urlsByName = const {},
  });
}

class UpdateService {
  /// One version ahead of the latest official release: this is the version
  /// the unreleased work on top of v3.9.8 reports as, so a local/Beta build
  /// reads as newer than the published app.
  static const String currentVersion = '6.2.4';

  /// True when this build runs from the Beta install. The Windows runner
  /// marks the Beta by its install folder (see windows/runner/main.cpp), so
  /// mirror that check here: Beta and release share one binary.
  static bool get isBetaBuild =>
      !kIsWeb &&
      Platform.isWindows &&
      Platform.resolvedExecutable.contains('Pear Music Beta');

  /// Version string for the UI. The Beta appends its channel name so a test
  /// build can never be mistaken for the official release of the same
  /// version.
  static String get displayVersion =>
      isBetaBuild ? '$currentVersion Beta' : currentVersion;

  /// Set whenever a release check completes, so the settings screen can
  /// badge the update entry without another network round-trip.
  static final ValueNotifier<bool> updateAvailable = ValueNotifier(false);
  static bool _checking = false;
  static const String _releasesApiUrl =
      'https://api.github.com/repos/Boci0/Pear-Music/releases/latest';

  /// Where the signed update manifest (`app-update.json` and its `.sig`) is
  /// published. Each host is asked, and the newest verified answer wins, so one
  /// host serving an old manifest cannot hold users back.
  static const List<String> manifestBases = [
    'https://github.com/Boci0/Pear-Music/releases/latest/download',
    'https://github.com/Boci0/pm-resolver-mirror/releases/download/app-update',
  ];

  /// Shows the update dialog for [info] (the control port's /sheet check).
  static Future<void> showUpdateDialogFor(BuildContext context, UpdateInfo info) =>
      showDialog(
        context: context,
        builder: (_) => _UpdateDialog(info: info, hostContext: context),
      );

  static Future<UpdateInfo?> checkLatestRelease() async {
    final signed = await _checkSignedManifest();
    if (signed != null) {
      updateAvailable.value = signed.hasUpdate;
      return signed;
    }
    return _checkLegacyRelease();
  }

  /// Fetches and verifies the manifest from one host, or null.
  static Future<AppUpdateManifest?> _fetchManifest(String base) async {
    final client = BackupAudioEngine.ipv4HttpClient(
      connectionTimeout: const Duration(seconds: 8),
    );
    try {
      client.userAgent = 'PearMusicApp/$currentVersion';
      Future<Uint8List?> get(String url) async {
        final request = await client
            .getUrl(Uri.parse(url))
            .timeout(const Duration(seconds: 8));
        final response =
            await request.close().timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) {
          await response.drain<void>();
          return null;
        }
        final out = BytesBuilder(copy: false);
        await for (final chunk
            in response.timeout(const Duration(seconds: 12))) {
          out.add(chunk);
          if (out.length > (1 << 20)) return null;
        }
        return out.takeBytes();
      }

      return await () async {
        final manifest = await get('$base/app-update.json');
        if (manifest == null) return null;
        final sig = await get('$base/app-update.json.sig');
        if (sig == null) return null;
        return AppUpdateManifest.parseVerified(
          manifest,
          Uint8List.fromList(base64.decode(utf8.decode(sig).trim())),
        );
      }().timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('[UpdateService] Manifest from $base unavailable: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<UpdateInfo?> _checkSignedManifest() async {
    final results = await Future.wait(manifestBases.map(_fetchManifest));
    AppUpdateManifest? best;
    for (final m in results) {
      if (m == null) continue;
      if (best == null || _isNewerVersion(best.version, m.version)) best = m;
    }
    if (best == null) return null;
    return buildInfoFromManifest(
      best,
      currentVersion: currentVersion,
      abis: await _androidAbis(),
    );
  }

  /// Turns a verified manifest into what the dialog and installers use.
  /// [abis] are the device's supported ABIs, most preferred first (Android).
  @visibleForTesting
  static UpdateInfo buildInfoFromManifest(
    AppUpdateManifest manifest, {
    required String currentVersion,
    List<String> abis = const [],
  }) {
    String? apkArm64, apkArmv7, apkX86, apkUniversal, setup, zip;
    final sha256ByName = <String, String>{};
    final urlsByName = <String, List<String>>{};
    for (final entry in manifest.assets.entries) {
      final name = entry.key;
      final lower = name.toLowerCase();
      final url = entry.value.urls.first;
      sha256ByName[name] = entry.value.sha256;
      urlsByName[name] = entry.value.urls;
      if (lower.endsWith('.apk')) {
        if (lower.contains('arm64')) {
          apkArm64 = url;
        } else if (lower.contains('armv7') || lower.contains('armeabi')) {
          apkArmv7 = url;
        } else if (lower.contains('x86_64')) {
          apkX86 = url;
        } else {
          apkUniversal = url;
        }
      } else if (lower.endsWith('.exe')) {
        setup = url;
      } else if (lower.endsWith('.zip')) {
        zip = url;
      }
    }
    return UpdateInfo(
      hasUpdate: _isNewerVersion(currentVersion, manifest.version),
      currentVersion: currentVersion,
      latestVersion: manifest.version,
      releaseNotes: manifest.notes,
      htmlUrl: manifest.page,
      apkUrl: selectApkUrl(
        abis: abis,
        arm64: apkArm64,
        armv7: apkArmv7,
        x86: apkX86,
        universal: apkUniversal,
      ),
      setupUrl: setup,
      zipUrl: zip,
      sha256ByName: sha256ByName,
      verified: true,
      urlsByName: urlsByName,
    );
  }

  /// Picks the APK that suits the device's ABIs, falling back to whatever the
  /// release has.
  @visibleForTesting
  static String? selectApkUrl({
    required List<String> abis,
    String? arm64,
    String? armv7,
    String? x86,
    String? universal,
  }) {
    final lower = abis.map((e) => e.toLowerCase()).toList();
    if (lower.any((a) => a.contains('arm64')) && arm64 != null) return arm64;
    if (lower.any((a) => a.contains('v7') || a.contains('arm')) &&
        armv7 != null) {
      return armv7;
    }
    if (lower.any((a) => a.contains('x86_64')) && x86 != null) return x86;
    // An unknown or unlisted CPU (an x86_64 head unit) can only run the
    // universal APK; the single-ABI ones would fail to install.
    return universal ?? x86 ?? arm64 ?? armv7;
  }

  /// The device's supported ABIs on Android, otherwise empty.
  static Future<List<String>> _androidAbis() async {
    if (defaultTargetPlatform != TargetPlatform.android) return const [];
    try {
      const channel = MethodChannel('peerm/ytdlp');
      final abis = await channel
          .invokeMethod<List<dynamic>>('getSupportedAbis')
          .timeout(const Duration(milliseconds: 600));
      return abis?.map((e) => e.toString()).toList() ?? const [];
    } catch (e) {
      DebugLog.write('[update] supported ABI query failed: $e');
      return const [];
    }
  }

  /// The old, unsigned path: GitHub's releases API. Its answer is only used to
  /// tell the user an update exists and to link the release page. Nothing it
  /// serves is installed in place, because its checksums come from the same
  /// host as the files.
  static Future<UpdateInfo?> _checkLegacyRelease() async {
    final client = BackupAudioEngine.ipv4HttpClient(
      connectionTimeout: const Duration(seconds: 8),
    );
    try {
      client.userAgent = 'PearMusicApp/$currentVersion';
      final request = await client
          .getUrl(Uri.parse(_releasesApiUrl))
          .timeout(const Duration(seconds: 8));
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );

      if (response.statusCode == 200) {
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 15));
        final json = jsonDecode(body) as Map<String, dynamic>;
        final tagName = (json['tag_name'] as String? ?? '').trim();
        final htmlUrl =
            (json['html_url'] as String? ??
            'https://github.com/Boci0/Pear-Music/releases');
        final bodyText =
            (json['body'] as String? ?? 'No release notes provided.').trim();

        String? apkUrl;
        String? apkArm64Url;
        String? apkArmv7Url;
        String? apkX86Url;
        String? apkUniversalUrl;
        String? setupUrl;
        String? zipUrl;
        String? sumsUrl;
        final assets = json['assets'] as List<dynamic>? ?? [];
        for (final asset in assets) {
          if (asset is Map<String, dynamic>) {
            final downloadUrl = asset['browser_download_url'] as String? ?? '';
            final name = (asset['name'] as String? ?? p.basename(downloadUrl))
                .toLowerCase();
            if (downloadUrl.endsWith('.apk')) {
              if (name.contains('arm64')) {
                apkArm64Url = downloadUrl;
              } else if (name.contains('armv7') || name.contains('armeabi')) {
                apkArmv7Url = downloadUrl;
              } else if (name.contains('x86_64')) {
                apkX86Url = downloadUrl;
              } else {
                apkUniversalUrl = downloadUrl;
              }
            } else if (downloadUrl.endsWith('.exe')) {
              setupUrl = downloadUrl;
            } else if (downloadUrl.endsWith('.zip')) {
              zipUrl = downloadUrl;
            } else if (name == 'sha256sums' || name == 'checksums.txt') {
              sumsUrl = downloadUrl;
            }
          }
        }

        apkUrl = selectApkUrl(
          abis: await _androidAbis(),
          arm64: apkArm64Url,
          armv7: apkArmv7Url,
          x86: apkX86Url,
          universal: apkUniversalUrl,
        );

        // Resolve expected SHA-256 digests so downloads can be verified
        // before install. Prefer the checksums asset; fall back to lines in
        // the release body like `<64-hex> PearMusic-1.6.4.apk`.
        var sha256ByName = await _fetchChecksumAsset(sumsUrl);
        if (sha256ByName.isEmpty) {
          sha256ByName = _parseBodyChecksums(bodyText);
        }

        final cleanLatest = _cleanVersion(tagName);
        final hasNewer = _isNewerVersion(currentVersion, cleanLatest);

        final info = UpdateInfo(
          hasUpdate: hasNewer,
          currentVersion: currentVersion,
          latestVersion: cleanLatest.isEmpty ? currentVersion : cleanLatest,
          releaseNotes: bodyText,
          htmlUrl: htmlUrl,
          apkUrl: apkUrl,
          setupUrl: setupUrl,
          zipUrl: zipUrl,
          sha256ByName: sha256ByName,
        );
        updateAvailable.value = info.hasUpdate;
        return info;
      }
    } catch (e) {
      debugPrint('[UpdateService] Check failed: $e');
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// Downloads and parses a `SHA256SUMS` / `checksums.txt` release asset into
  /// a filename -> digest map. Returns an empty map on any failure.
  static Future<Map<String, String>> _fetchChecksumAsset(
    String? sumsUrl,
  ) async {
    final result = <String, String>{};
    if (sumsUrl == null || !sumsUrl.startsWith('https://')) return result;
    final client = BackupAudioEngine.ipv4HttpClient(
      connectionTimeout: const Duration(seconds: 8),
    );
    try {
      client.userAgent = 'PearMusicApp/$currentVersion';
      final request = await client
          .getUrl(Uri.parse(sumsUrl))
          .timeout(const Duration(seconds: 8));
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode == 200) {
        final text = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 15));
        for (final line in const LineSplitter().convert(text)) {
          final m = RegExp(
            r'^([0-9a-fA-F]{64})\s+\*?(.+)$',
          ).firstMatch(line.trim());
          if (m != null) {
            final fileName = p.basename(m.group(2)!.trim());
            final hash = m.group(1)!.toLowerCase();
            result[fileName] = hash;
          }
        }
      }
    } catch (e) {
      debugPrint('[UpdateService] Failed to fetch checksums asset: $e');
    } finally {
      client.close(force: true);
    }
    return result;
  }

  /// Scans release-notes text for `<64-char hex digest>` paired with an
  /// `.apk`/`.zip`/`.exe` filename on the same line.
  @visibleForTesting
  static Map<String, String> parseBodyChecksumsForTest(String body) =>
      _parseBodyChecksums(body);

  static Map<String, String> _parseBodyChecksums(String body) {
    final result = <String, String>{};
    for (final line in const LineSplitter().convert(body)) {
      final m = RegExp(
        r'([0-9a-fA-F]{64})[\s`*_\-:]*(?:\[)?([\w.\-]+\.(?:apk|zip|exe))',
      ).firstMatch(line);
      if (m != null) {
        result[m.group(2)!] = m.group(1)!.toLowerCase();
      }
    }
    return result;
  }

  /// Finds the expected SHA-256 for a given filename using case-insensitive lookup.
  static String? _findExpectedHash(UpdateInfo info, String filename) {
    final key = filename.toLowerCase();
    for (final entry in info.sha256ByName.entries) {
      if (entry.key.toLowerCase() == key) {
        return entry.value.toLowerCase();
      }
    }
    return null;
  }

  /// Streams [file] through SHA-256 on a worker isolate and returns the
  /// lowercase hex digest.
  static Future<String> computeFileSha256(File file) =>
      ResumableDownloader.computeFileSha256(file);

  static String _cleanVersion(String tag) {
    return tag.replaceAll(RegExp(r'[^0-9\.]'), '');
  }

  static bool _isNewerVersion(String current, String latest) {
    if (latest.isEmpty) return false;
    final currParts = current
        .split('-')
        .first
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final lateParts = latest
        .split('-')
        .first
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();

    final partCount =
        currParts.length > lateParts.length ? currParts.length : lateParts.length;
    for (var i = 0; i < partCount; i++) {
      final c = i < currParts.length ? currParts[i] : 0;
      final l = i < lateParts.length ? lateParts[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }

  static Future<void> checkForUpdates(
    BuildContext context, {
    bool quiet = false,
  }) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    if (_checking) {
      if (!quiet) {
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text('Already checking for updates...'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    _checking = true;
    try {
      if (!quiet) {
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text('Checking GitHub for updates...'),
            duration: Duration(seconds: 2),
          ),
        );
      }

      final info = await checkLatestRelease();

      if (!context.mounted) return;

      if (info == null) {
        if (!quiet) {
          scaffoldMessenger.showSnackBar(
            const SnackBar(
              content: Text('Could not reach GitHub Releases API.'),
            ),
          );
        }
        return;
      }

      if (info.hasUpdate) {
        showDialog(
          context: context,
          builder: (ctx) => _UpdateDialog(info: info, hostContext: context),
        );
      } else {
        if (!quiet) {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(
                'Pear Music is up to date (v${info.currentVersion})',
              ),
            ),
          );
        }
      }
    } finally {
      _checking = false;
    }
  }

  /// Shows the "verification data missing" dialog with an option to open the
  /// GitHub release page (never installs/extracts in this state).
  static Future<void> _showMissingHashDialog(
    BuildContext context,
    UpdateInfo info,
  ) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => PearAlertDialog(
        title: const Text('Cannot verify update'),
        content: const Text(
          'This release does not include SHA-256 verification data '
          '(SHA256SUMS / checksums.txt). For your safety, the update will not '
          'be installed automatically.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              launchUrl(
                Uri.parse(info.htmlUrl),
                mode: LaunchMode.externalApplication,
              );
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open release page'),
          ),
        ],
      ),
    );
  }

  /// Shown when an update exists but its signature could not be checked (no
  /// signed manifest was reachable). Nothing is installed in place.
  static Future<void> _showUnverifiedDialog(
    BuildContext context,
    UpdateInfo info,
  ) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => PearAlertDialog(
        title: const Text('Cannot verify update'),
        content: const Text(
          'This update could not be checked against its signature, so it '
          'will not be installed automatically. You can still get it from the '
          'release page.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              launchUrl(
                Uri.parse(info.htmlUrl),
                mode: LaunchMode.externalApplication,
              );
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open release page'),
          ),
        ],
      ),
    );
  }

  static Future<void> _safeDeleteFile(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('[UpdateService] Safe delete suppressed for ${file.path}: $e');
    }
  }

  /// Picks the file to download the Windows ZIP update into. Normally the
  /// canonical `peerm_update.zip`; when that file is still held open (a
  /// previous updater run, an antivirus scan), Windows refuses the delete, so
  /// a per-attempt name is used instead of failing the whole update.
  static Future<File> _resolveDownloadTarget(Directory tempDir) async {
    final canonical = File(p.join(tempDir.path, 'peerm_update.zip'));
    if (!await canonical.exists()) return canonical;
    await _safeDeleteFile(canonical);
    if (!await canonical.exists()) return canonical;

    final unique = File(p.join(
      tempDir.path,
      'peerm_update_${DateTime.now().millisecondsSinceEpoch}.zip',
    ));
    debugPrint(
      '[UpdateService] Canonical update file is locked; downloading to ${p.basename(unique.path)}',
    );
    await _safeDeleteFile(unique);
    return unique;
  }

  /// Finds a verified ZIP left behind by an earlier attempt (per-attempt names
  /// are used when the canonical file was locked). Unverifiable leftovers are
  /// deleted so the temp directory does not accumulate them.
  static Future<File?> _findVerifiedLeftover(
    Directory tempDir,
    String expected,
  ) async {
    try {
      await for (final entry in tempDir.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = p.basename(entry.path);
        if (!name.startsWith('peerm_update_') || !name.endsWith('.zip')) {
          continue;
        }
        if (await entry.length() == 0) continue;
        final actual = await computeFileSha256(entry);
        if (actual.toLowerCase() == expected.trim().toLowerCase()) {
          return entry;
        }
        await _safeDeleteFile(entry);
      }
    } catch (e) {
      debugPrint('[UpdateService] Leftover scan failed: $e');
    }
    return null;
  }

  @visibleForTesting
  static Future<File> resolveDownloadTargetForTesting(Directory tempDir) =>
      _resolveDownloadTarget(tempDir);

  static Future<File?> getVerifiedDownloadedUpdate(UpdateInfo info) async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (defaultTargetPlatform == TargetPlatform.android &&
          info.apkUrl != null) {
        final expected = _findExpectedHash(info, p.basename(info.apkUrl!));
        if (expected == null || expected.isEmpty) return null;
        final apkFile = File(p.join(tempDir.path, 'PearMusic-update.apk'));
        if (await apkFile.exists() && await apkFile.length() > 0) {
          final actual = await computeFileSha256(apkFile);
          if (actual.toLowerCase() == expected.trim().toLowerCase()) {
            return apkFile;
          }
          // The cached file belongs to an older release or is corrupt:
          // remove it so the downloader starts clean and the space is freed.
          try {
            await apkFile.delete();
          } catch (_) {}
        }
      } else if (defaultTargetPlatform == TargetPlatform.windows &&
          info.zipUrl != null) {
        final expected = _findExpectedHash(info, p.basename(info.zipUrl!));
        if (expected == null || expected.isEmpty) return null;
        final zipFile = File(p.join(tempDir.path, 'peerm_update.zip'));
        try {
          if (await zipFile.exists() && await zipFile.length() > 0) {
            final actual = await computeFileSha256(zipFile);
            if (actual.toLowerCase() == expected.trim().toLowerCase()) {
              return zipFile;
            }
            await _safeDeleteFile(zipFile);
          }
        } catch (e) {
          DebugLog.write('[update] cached update zip check failed: $e');
        }

        try {
          await for (final entry in tempDir.list(followLinks: false)) {
            if (entry is File &&
                p.basename(entry.path).startsWith('peerm_update_') &&
                entry.path.endsWith('.zip')) {
              try {
                if (await entry.length() > 0) {
                  final actual = await computeFileSha256(entry);
                  if (actual.toLowerCase() == expected.trim().toLowerCase()) {
                    return entry;
                  }
                  await _safeDeleteFile(entry);
                }
              } catch (e) {
                DebugLog.write('[update] cached update file check failed: $e');
              }
            }
          }
        } catch (e) {
          DebugLog.write('[update] cached update folder scan failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[UpdateService] Check cached update failed: $e');
    }
    return null;
  }

  static Future<bool> canRequestPackageInstalls() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      const channel = MethodChannel('peerm/ytdlp');
      final res = await channel.invokeMethod<bool>('canRequestPackageInstalls');
      return res ?? true;
    } catch (e) {
      DebugLog.write('[update] install permission query failed: $e');
      return true;
    }
  }

  static Future<bool> openInstallPermissionSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      const channel = MethodChannel('peerm/ytdlp');
      final res =
          await channel.invokeMethod<bool>('openInstallPermissionSettings');
      return res ?? false;
    } catch (e) {
      DebugLog.write('[update] opening install permission settings failed: $e');
      return false;
    }
  }

  static Future<void> installApkDirectly(String path) async {
    const channel = MethodChannel('peerm/ytdlp');
    await channel.invokeMethod('installApk', {'path': path});
  }

  static Future<void> showPermissionPrompt(BuildContext context) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => PearAlertDialog(
        title: const Text('Install Permission Required'),
        content: const Text(
          'Pear Music needs permission to install downloaded app updates. '
          'Please enable "Allow from this source" in Settings to continue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              openInstallPermissionSettings();
            },
            icon: const Icon(Icons.settings),
            label: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  /// Downloads from each of [urls] in turn into [file] until one gives a file
  /// whose SHA-256 is [expected]. Returns null on success, otherwise the
  /// message to show the user.
  static Future<String?> _downloadVerifiedZip(
    List<String> urls,
    File file,
    String expected, {
    void Function(int received, int total)? onProgress,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    Duration connectionTimeout = const Duration(seconds: 12),
    Duration responseTimeout = const Duration(seconds: 15),
    Duration stallTimeout = const Duration(seconds: 25),
  }) async {
    final result = await ResumableDownloader.downloadToFile(
      urls: urls,
      destFile: file,
      expectedSha256: expected,
      headers: const {'User-Agent': 'PearMusicApp/$currentVersion'},
      connectionTimeout: connectionTimeout,
      responseTimeout: responseTimeout,
      stallTimeout: stallTimeout,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
    );
    return result.success ? null : (result.error ?? 'Download failed.');
  }

  /// Test seam for fault-injection testing of resumable ZIP updates, stalls,
  /// cancellations, and mirror failover.
  @visibleForTesting
  static Future<String?> downloadVerifiedZipForTesting(
    List<String> urls,
    File file,
    String expected, {
    void Function(int received, int total)? onProgress,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    Duration connectionTimeout = const Duration(seconds: 2),
    Duration responseTimeout = const Duration(seconds: 2),
    Duration stallTimeout = const Duration(seconds: 2),
  }) => _downloadVerifiedZip(
    urls,
    file,
    expected,
    onProgress: onProgress,
    shouldCancel: shouldCancel,
    cancelSignal: cancelSignal,
    connectionTimeout: connectionTimeout,
    responseTimeout: responseTimeout,
    stallTimeout: stallTimeout,
  );

  static Future<bool> downloadAndApplyWindowsZip(
    BuildContext context,
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    void Function(String message)? onError,
    bool showErrorSnackBar = true,
  }) async {
    final zipUrl = info.zipUrl!;
    final scaffoldMessenger = ScaffoldMessenger.maybeOf(context);
    if (!info.verified) {
      if (context.mounted) {
        await _showUnverifiedDialog(context, info);
      }
      return false;
    }

    try {
      final tempDir = await getTemporaryDirectory();
      var zipFile = File(p.join(tempDir.path, 'peerm_update.zip'));

      // Integrity gate: never extract/relaunch without a matching SHA-256.
      final expected = _findExpectedHash(info, p.basename(zipUrl));
      if (expected == null || expected.isEmpty) {
        debugPrint(
          '[UpdateService] No SHA-256 data for ${p.basename(zipUrl)}',
        );
        await _safeDeleteFile(zipFile);
        if (context.mounted) {
          await _showMissingHashDialog(context, info);
        }
        return false;
      }

      bool needDownload = true;
      if (await zipFile.exists() && await zipFile.length() > 0) {
        final existingHash = await computeFileSha256(zipFile);
        if (existingHash.toLowerCase() == expected.trim().toLowerCase()) {
          needDownload = false;
          debugPrint('[UpdateService] Reusing verified cached ZIP update.');
        }
      }
      if (needDownload) {
        final leftover = await _findVerifiedLeftover(tempDir, expected);
        if (leftover != null) {
          zipFile = leftover;
          needDownload = false;
          debugPrint(
            '[UpdateService] Reusing verified ZIP from an earlier attempt.',
          );
        }
      }

      if (needDownload) {
        if (onProgress == null) {
          scaffoldMessenger?.showSnackBar(
            const SnackBar(
              content: Text('Downloading update package...'),
              duration: Duration(seconds: 5),
            ),
          );
        }
        // Never fail because a stale file cannot be removed; fall back to a
        // per-attempt name in that case.
        zipFile = await _resolveDownloadTarget(tempDir);

        final failure = await _downloadVerifiedZip(
          info.urlsByName[p.basename(zipUrl)] ?? [zipUrl],
          zipFile,
          expected,
          onProgress: onProgress,
          shouldCancel: shouldCancel,
          cancelSignal: cancelSignal,
        );
        if (failure != null) {
          onError?.call(failure);
          if (showErrorSnackBar) {
            scaffoldMessenger?.showSnackBar(
              SnackBar(
                content: Text(failure),
                duration: const Duration(seconds: 6),
              ),
            );
          }
          return false;
        }
      }

      final exePath = Platform.resolvedExecutable;
      final appDir = p.dirname(exePath);

      final updaterScript = File(p.join(tempDir.path, 'peerm_updater.ps1'));
      await updaterScript.writeAsString('''
param(
    [int]\$AppPid,
    [string]\$ZipPath,
    [string]\$AppDir,
    [string]\$ExePath
)

\$logFile = Join-Path \$env:TEMP 'peerm_updater.log'
"\$(Get-Date): Updater launched for PID \$AppPid" | Out-File -FilePath \$logFile -Encoding utf8

if (\$AppPid -gt 0) {
    try {
        Wait-Process -Id \$AppPid -Timeout 15 -ErrorAction SilentlyContinue
    } catch {}
}
Start-Sleep -Milliseconds 1000

\$retries = 8
\$extracted = \$false
while (\$retries -gt 0 -and -not \$extracted) {
    try {
        Expand-Archive -LiteralPath \$ZipPath -DestinationPath \$AppDir -Force -ErrorAction Stop
        \$extracted = \$true
        "\$(Get-Date): Extraction succeeded into \$AppDir" | Out-File -FilePath \$logFile -Append -Encoding utf8
    } catch {
        "\$(Get-Date): Extract retry (\$retries attempts left): \$(\$_.Exception.Message)" | Out-File -FilePath \$logFile -Append -Encoding utf8
        \$retries--
        Start-Sleep -Seconds 1
    }
}

if (\$extracted) {
    # Keep the Installed apps entry from install.ps1 in step with the new build.
    try {
        \$ver = (Get-Item -LiteralPath \$ExePath).VersionInfo.ProductVersion -replace '\\+.*\$', ''
        \$reg = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\PearMusic'
        \$loc = (Get-ItemProperty -Path \$reg -Name InstallLocation -ErrorAction Stop).InstallLocation
        if (\$ver -and \$loc.TrimEnd('\\') -ieq \$AppDir.TrimEnd('\\')) {
            Set-ItemProperty -Path \$reg -Name DisplayVersion -Value \$ver
        }
    } catch {}
    Start-Process -FilePath \$ExePath
    "\$(Get-Date): Launched \$ExePath" | Out-File -FilePath \$logFile -Append -Encoding utf8
    Remove-Item -LiteralPath \$ZipPath -Force -ErrorAction SilentlyContinue
} else {
    "\$(Get-Date): Extraction failed after all retries." | Out-File -FilePath \$logFile -Append -Encoding utf8
}

Remove-Item -LiteralPath \$PSCommandPath -Force -ErrorAction SilentlyContinue
''');

      final currentPid = pid;
      final cmdLine =
          'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden '
          '-File "${updaterScript.path}" -AppPid $currentPid -ZipPath "${zipFile.path}" '
          '-AppDir "$appDir" -ExePath "$exePath"';

      bool launchedViaChannel = false;
      try {
        const channel = MethodChannel('peerm/windows_updater');
        final ok = await channel.invokeMethod<bool>('startDetachedProcess', {
          'commandLine': cmdLine,
        });
        launchedViaChannel = ok ?? false;
      } catch (e) {
        debugPrint('[UpdateService] Native breakaway launch failed: $e');
      }

      if (!launchedViaChannel) {
        await Process.start('powershell.exe', [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          updaterScript.path,
          '-AppPid',
          '$currentPid',
          '-ZipPath',
          zipFile.path,
          '-AppDir',
          appDir,
          '-ExePath',
          exePath,
        ], mode: ProcessStartMode.detached);
      }

      exit(0);
    } catch (e) {
      debugPrint('[UpdateService] Native ZIP update failed: $e');
      onError?.call('Automatic update failed: $e');
      if (showErrorSnackBar) {
        scaffoldMessenger?.showSnackBar(
          SnackBar(content: Text('Automatic update failed: $e')),
        );
      }
      return false;
    }
  }

  static Future<void> downloadAndInstallAndroidApk(
    BuildContext context,
    UpdateInfo info,
  ) async {
    final apkUrl = info.apkUrl!;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    if (!info.verified) {
      if (context.mounted) {
        await _showUnverifiedDialog(context, info);
      }
      return;
    }

    // Integrity gate: refuse to download/install without expected SHA-256.
    final expected = _findExpectedHash(info, p.basename(apkUrl));
    if (expected == null || expected.isEmpty) {
      debugPrint('[UpdateService] No SHA-256 data for ${p.basename(apkUrl)}');
      if (context.mounted) {
        await _showMissingHashDialog(context, info);
      }
      return;
    }

    final cachedApk = await getVerifiedDownloadedUpdate(info);
    if (cachedApk != null) {
      final canInstall = await canRequestPackageInstalls();
      if (!canInstall && context.mounted) {
        await showPermissionPrompt(context);
        return;
      }
      try {
        await installApkDirectly(cachedApk.path);
        return;
      } catch (e) {
        debugPrint('[UpdateService] Direct install error: $e');
      }
    }

    scaffoldMessenger.showSnackBar(
      const SnackBar(
        content: Text('Downloading update in notifications...'),
        duration: Duration(seconds: 3),
      ),
    );
    const channel = MethodChannel('peerm/ytdlp');
    Object? lastError;
    // Try each host in turn: the native side checks the SHA-256 itself, so a
    // mirror serving the wrong bytes just fails over to the next one.
    for (final url in info.urlsByName[p.basename(apkUrl)] ?? [apkUrl]) {
      try {
        await channel.invokeMethod('downloadApkWithNotification', {
          'url': url,
          'fileName': 'PearMusic-update.apk',
          'expectedSha256': expected,
        });
        return;
      } on PlatformException catch (e) {
        debugPrint('[UpdateService] Android in-app update from $url failed: $e');
        if (e.code == 'hash_missing') {
          if (context.mounted) await _showMissingHashDialog(context, info);
          return;
        }
        lastError = e;
      } catch (e) {
        debugPrint('[UpdateService] Android in-app update from $url failed: $e');
        lastError = e;
      }
    }
    if (lastError is PlatformException && lastError.code == 'hash_mismatch') {
      scaffoldMessenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Checksum mismatch: the downloaded APK failed verification '
            'and was deleted.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
    } else {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('In-app update error: $lastError')),
      );
    }
  }
}

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  final BuildContext hostContext;
  const _UpdateDialog({required this.info, required this.hostContext});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  File? _cachedFile;
  bool _handling = false;
  bool _downloading = false;
  bool _cancelled = false;
  Completer<void> _cancelCompleter = Completer<void>();
  int _receivedBytes = 0;
  int _totalBytes = 0;
  DateTime _lastProgressUi = DateTime.fromMillisecondsSinceEpoch(0);
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _checkCache();
  }

  @override
  void dispose() {
    if (_downloading && !_cancelCompleter.isCompleted) {
      _cancelled = true;
      _cancelCompleter.complete();
    }
    super.dispose();
  }

  Future<void> _checkCache() async {
    final cached = await UpdateService.getVerifiedDownloadedUpdate(widget.info);
    if (mounted) {
      setState(() {
        _cachedFile = cached;
      });
    }
  }

  Future<void> _handleUpdate(BuildContext context) async {
    if (_handling) return;
    _handling = true;
    final hostContext = widget.hostContext;
    try {
      if (defaultTargetPlatform == TargetPlatform.windows &&
          widget.info.zipUrl != null &&
          widget.info.verified) {
        final expected = UpdateService._findExpectedHash(
          widget.info,
          p.basename(widget.info.zipUrl!),
        );
        if (expected == null || expected.isEmpty) {
          Navigator.pop(context);
          if (hostContext.mounted) {
            await UpdateService.downloadAndApplyWindowsZip(
              hostContext,
              widget.info,
            );
          }
          return;
        }

        setState(() {
          _downloading = true;
          _cancelled = false;
          _cancelCompleter = Completer<void>();
          _receivedBytes = 0;
          _totalBytes = 0;
          _errorMessage = null;
        });

        await UpdateService.downloadAndApplyWindowsZip(
          hostContext,
          widget.info,
          showErrorSnackBar: false,
          shouldCancel: () => _cancelled || !mounted,
          cancelSignal: _cancelCompleter.future,
          onProgress: (received, total) {
            if (!mounted) return;
            final now = DateTime.now();
            if (received < total &&
                now.difference(_lastProgressUi).inMilliseconds < 120) {
              return;
            }
            _lastProgressUi = now;
            setState(() {
              _receivedBytes = received;
              _totalBytes = total;
            });
          },
          onError: (msg) {
            if (!mounted) return;
            setState(() {
              _downloading = false;
              _errorMessage = _cancelled ? null : msg;
            });
          },
        );
        if (mounted && _downloading) {
          setState(() => _downloading = false);
        }
        return;
      }

      if (defaultTargetPlatform == TargetPlatform.android &&
          widget.info.apkUrl != null &&
          widget.info.verified) {
        if (_cachedFile != null) {
          final canInstall = await UpdateService.canRequestPackageInstalls();
          if (!canInstall) {
            if (context.mounted) {
              await UpdateService.showPermissionPrompt(context);
            } else if (hostContext.mounted) {
              await UpdateService.showPermissionPrompt(hostContext);
            }
            return;
          }
          if (context.mounted) {
            Navigator.pop(context);
          }
          try {
            await UpdateService.installApkDirectly(_cachedFile!.path);
          } catch (e) {
            debugPrint('[UpdateService] Direct cached APK install failed: $e');
          }
          return;
        }
        Navigator.pop(context);
        if (hostContext.mounted) {
          await UpdateService.downloadAndInstallAndroidApk(
            hostContext,
            widget.info,
          );
        }
        return;
      }

      String targetUrl = widget.info.htmlUrl;
      if (defaultTargetPlatform == TargetPlatform.windows &&
          widget.info.verified) {
        if (widget.info.setupUrl != null) {
          targetUrl = widget.info.setupUrl!;
        }
      }

      try {
        final uri = Uri.parse(targetUrl);
        final launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (!launched) {
          final fallbackUri = Uri.parse(widget.info.htmlUrl);
          await launchUrl(fallbackUri, mode: LaunchMode.externalApplication);
        }
      } catch (e) {
        debugPrint('[UpdateService] Failed to launch $targetUrl: $e');
        try {
          final fallbackUri = Uri.parse(widget.info.htmlUrl);
          await launchUrl(fallbackUri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      }
      if (context.mounted) Navigator.pop(context);
    } finally {
      _handling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAndroidWithApk =
        defaultTargetPlatform == TargetPlatform.android &&
        widget.info.apkUrl != null &&
        widget.info.verified;
    final isWindowsWithZip =
        defaultTargetPlatform == TargetPlatform.windows &&
        widget.info.zipUrl != null &&
        widget.info.verified;
    final isReadyToInstall = _cachedFile != null;

    String buttonLabel = 'Get Update';
    IconData buttonIcon = Icons.file_download;

    if (isReadyToInstall) {
      buttonLabel = isWindowsWithZip ? 'Install & Restart' : 'Install Update';
      buttonIcon = Icons.system_update_rounded;
    } else if (_errorMessage != null && isWindowsWithZip) {
      buttonLabel = 'Retry';
      buttonIcon = Icons.refresh_rounded;
    } else if (isAndroidWithApk) {
      buttonLabel = 'Download APK';
      buttonIcon = Icons.file_download;
    } else if (isWindowsWithZip) {
      buttonLabel = 'Update Automatically';
      buttonIcon = Icons.system_update;
    }

    final progressValue =
        _totalBytes > 0 ? (_receivedBytes / _totalBytes).clamp(0.0, 1.0) : null;
    final downloadedMb = (_receivedBytes / (1024 * 1024)).toStringAsFixed(1);
    final totalMb = (_totalBytes / (1024 * 1024)).toStringAsFixed(1);

    return PearAlertDialog(
      title: Text('Update Available (${widget.info.latestVersion})'),
      // AlertDialog sizes to its content's intrinsic width, and the release
      // notes' unwrapped changelog lines would stretch it across the window.
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('A new version of Pear Music is available!'),
            const SizedBox(height: 12),
            Text(
              'Current: v${widget.info.currentVersion}  ->  Latest: v${widget.info.latestVersion}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            if (!widget.info.verified) ...[
              const SizedBox(height: 10),
              Text(
                'This update could not be checked against its signature, so '
                'it opens the release page instead of installing here.',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
            if (_downloading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progressValue),
              const SizedBox(height: 6),
              Text(
                _totalBytes > 0
                    ? 'Downloading update: $downloadedMb / $totalMb MB (${((progressValue ?? 0) * 100).round()}%)'
                    : 'Downloading update ($downloadedMb MB)...',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ] else if (_errorMessage != null) ...[
              const SizedBox(height: 10),
              Text(
                _errorMessage!,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            if (isReadyToInstall) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withAlpha(80),
                  borderRadius: BorderRadius.circular(PearGlassTokens.r(8)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Update package already downloaded and verified.',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: SingleChildScrollView(
                child: Text(
                  widget.info.releaseNotes,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_downloading)
          TextButton(
            onPressed: () {
              setState(() => _cancelled = true);
              if (!_cancelCompleter.isCompleted) {
                _cancelCompleter.complete();
              }
              Navigator.pop(context);
            },
            child: const Text('Cancel'),
          )
        else ...[
          if (_errorMessage != null)
            TextButton(
              onPressed: () {
                launchUrl(
                  Uri.parse(widget.info.htmlUrl),
                  mode: LaunchMode.externalApplication,
                );
              },
              child: const Text('Open release page'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          FilledButton.icon(
            onPressed: () => _handleUpdate(context),
            icon: Icon(buttonIcon),
            label: Text(buttonLabel),
          ),
        ],
      ],
    );
  }
}
