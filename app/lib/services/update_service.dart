import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

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
  });
}

class UpdateService {
  static const String currentVersion = '2.7.1';

  /// Set whenever a release check completes, so the settings screen can
  /// badge the update entry without another network round-trip.
  static final ValueNotifier<bool> updateAvailable = ValueNotifier(false);
  static const String _releasesApiUrl =
      'https://api.github.com/repos/Boci0/Pear-Music/releases/latest';

  static Future<UpdateInfo?> checkLatestRelease() async {
    try {
      final client = HttpClient();
      client.userAgent = 'PearMusicApp/$currentVersion';
      final request = await client.getUrl(Uri.parse(_releasesApiUrl));
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
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

        // Select the best matching APK for this Android device architecture
        if (defaultTargetPlatform == TargetPlatform.android) {
          try {
            const channel = MethodChannel('peerm/ytdlp');
            final abis = await channel
                .invokeMethod<List<dynamic>>('getSupportedAbis')
                .timeout(const Duration(milliseconds: 600));
            final abisList =
                abis?.map((e) => e.toString().toLowerCase()).toList() ?? [];
            if (abisList.any((a) => a.contains('arm64')) &&
                apkArm64Url != null) {
              apkUrl = apkArm64Url;
            } else if (abisList.any(
                  (a) => a.contains('v7') || a.contains('arm'),
                ) &&
                apkArmv7Url != null) {
              apkUrl = apkArmv7Url;
            } else if (abisList.any((a) => a.contains('x86_64')) &&
                apkX86Url != null) {
              apkUrl = apkX86Url;
            } else {
              apkUrl =
                  apkArm64Url ?? apkArmv7Url ?? apkUniversalUrl ?? apkX86Url;
            }
          } catch (_) {
            apkUrl = apkArm64Url ?? apkArmv7Url ?? apkUniversalUrl ?? apkX86Url;
          }
        } else {
          apkUrl = apkArm64Url ?? apkArmv7Url ?? apkUniversalUrl ?? apkX86Url;
        }

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
    try {
      final client = HttpClient();
      client.userAgent = 'PearMusicApp/$currentVersion';
      final request = await client.getUrl(Uri.parse(sumsUrl));
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode == 200) {
        final text = await response.transform(utf8.decoder).join();
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

  /// Streams [file] through SHA-256 and returns the lowercase hex digest.
  static Future<String> computeFileSha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static String _cleanVersion(String tag) {
    return tag.replaceAll(RegExp(r'[^0-9\.]'), '');
  }

  static bool _isNewerVersion(String current, String latest) {
    if (latest.isEmpty) return false;
    final currParts = current
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final lateParts = latest
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();

    for (var i = 0; i < 3; i++) {
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
          const SnackBar(content: Text('Could not reach GitHub Releases API.')),
        );
      }
      return;
    }

    if (info.hasUpdate) {
      showDialog(
        context: context,
        builder: (ctx) => _UpdateDialog(info: info),
      );
    } else {
      if (!quiet) {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Pear Music is up to date (v${info.currentVersion})'),
          ),
        );
      }
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
      builder: (ctx) => AlertDialog(
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

  static Future<void> downloadAndApplyWindowsZip(
    BuildContext context,
    UpdateInfo info,
  ) async {
    final zipUrl = info.zipUrl!;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    scaffoldMessenger.showSnackBar(
      const SnackBar(
        content: Text('Downloading update package...'),
        duration: Duration(seconds: 5),
      ),
    );

    try {
      final tempDir = await getTemporaryDirectory();
      final zipFile = File(p.join(tempDir.path, 'peerm_update.zip'));
      if (await zipFile.exists()) await zipFile.delete();

      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(zipUrl));
      final response = await request.close();

      if (response.statusCode == 200) {
        final sink = zipFile.openWrite();
        await response.pipe(sink);
        await sink.close();

        // Integrity gate: never extract/relaunch without a matching SHA-256.
        final expected = _findExpectedHash(info, p.basename(zipUrl));
        if (expected == null || expected.isEmpty) {
          debugPrint(
            '[UpdateService] No SHA-256 data for ${p.basename(zipUrl)}',
          );
          await zipFile.delete();
          if (context.mounted) {
            await _showMissingHashDialog(context, info);
          }
          return;
        }
        final actual = await computeFileSha256(zipFile);
        if (actual != expected) {
          debugPrint('[UpdateService] Checksum mismatch: $actual != $expected');
          try {
            await zipFile.delete();
          } catch (_) {}
          scaffoldMessenger.showSnackBar(
            const SnackBar(
              content: Text(
                'Checksum mismatch — the downloaded update failed verification '
                'and was deleted.',
              ),
              duration: Duration(seconds: 6),
            ),
          );
          return;
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
    Start-Process -FilePath \$ExePath
    "\$(Get-Date): Launched \$ExePath" | Out-File -FilePath \$logFile -Append -Encoding utf8
    Remove-Item -LiteralPath \$ZipPath -Force -ErrorAction SilentlyContinue
} else {
    "\$(Get-Date): Extraction failed after all retries." | Out-File -FilePath \$logFile -Append -Encoding utf8
}

Remove-Item -LiteralPath \$PSCommandPath -Force -ErrorAction SilentlyContinue
''');

        final currentPid = pid;
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
        ], mode: ProcessStartMode.inheritStdio);

        exit(0);
      } else {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('Download failed (HTTP ${response.statusCode})'),
          ),
        );
      }
    } catch (e) {
      debugPrint('[UpdateService] Native ZIP update failed: $e');
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Automatic update failed: $e')),
      );
    }
  }

  static Future<void> downloadAndInstallAndroidApk(
    BuildContext context,
    UpdateInfo info,
  ) async {
    final apkUrl = info.apkUrl!;
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    // Integrity gate: refuse to download/install without expected SHA-256.
    final expected = _findExpectedHash(info, p.basename(apkUrl));
    if (expected == null || expected.isEmpty) {
      debugPrint('[UpdateService] No SHA-256 data for ${p.basename(apkUrl)}');
      await _showMissingHashDialog(context, info);
      return;
    }

    scaffoldMessenger.showSnackBar(
      const SnackBar(
        content: Text('Downloading update in notifications...'),
        duration: Duration(seconds: 3),
      ),
    );
    try {
      const channel = MethodChannel('peerm/ytdlp');
      await channel.invokeMethod('downloadApkWithNotification', {
        'url': apkUrl,
        'fileName': 'PearMusic-update.apk',
        'expectedSha256': expected,
      });
    } on PlatformException catch (e) {
      debugPrint('[UpdateService] Android in-app update failed: $e');
      if (e.code == 'hash_missing') {
        if (context.mounted) await _showMissingHashDialog(context, info);
      } else if (e.code == 'hash_mismatch') {
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Checksum mismatch — the downloaded APK failed verification '
              'and was deleted.',
            ),
            duration: Duration(seconds: 6),
          ),
        );
      } else {
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text('In-app update error: $e')),
        );
      }
    } catch (e) {
      debugPrint('[UpdateService] Android in-app update failed: $e');
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('In-app update error: $e')),
      );
    }
  }
}

class _UpdateDialog extends StatelessWidget {
  final UpdateInfo info;
  const _UpdateDialog({required this.info});

  Future<void> _handleUpdate(BuildContext context) async {
    if (defaultTargetPlatform == TargetPlatform.windows &&
        info.zipUrl != null) {
      Navigator.pop(context);
      await UpdateService.downloadAndApplyWindowsZip(context, info);
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.android &&
        info.apkUrl != null) {
      Navigator.pop(context);
      await UpdateService.downloadAndInstallAndroidApk(context, info);
      return;
    }

    String targetUrl = info.htmlUrl;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      if (info.setupUrl != null) {
        targetUrl = info.setupUrl!;
      }
    }

    try {
      final uri = Uri.parse(targetUrl);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        final fallbackUri = Uri.parse(info.htmlUrl);
        await launchUrl(fallbackUri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('[UpdateService] Failed to launch $targetUrl: $e');
      try {
        final fallbackUri = Uri.parse(info.htmlUrl);
        await launchUrl(fallbackUri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
    if (context.mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isAndroidWithApk =
        defaultTargetPlatform == TargetPlatform.android && info.apkUrl != null;
    final isWindowsWithZip =
        defaultTargetPlatform == TargetPlatform.windows && info.zipUrl != null;

    String buttonLabel = 'Get Update';
    if (isAndroidWithApk) {
      buttonLabel = 'Download APK';
    } else if (isWindowsWithZip) {
      buttonLabel = 'Update Automatically';
    }

    return AlertDialog(
      title: Text('Update Available (${info.latestVersion})'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('A new version of Pear Music is available!'),
          const SizedBox(height: 12),
          Text(
            'Current: v${info.currentVersion}  ->  Latest: v${info.latestVersion}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 140),
            child: SingleChildScrollView(
              child: Text(
                info.releaseNotes,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Later'),
        ),
        FilledButton.icon(
          onPressed: () => _handleUpdate(context),
          icon: Icon(
            isWindowsWithZip ? Icons.system_update : Icons.file_download,
          ),
          label: Text(buttonLabel),
        ),
      ],
    );
  }
}
