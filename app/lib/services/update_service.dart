import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:peerm_ytdlp/peerm_ytdlp.dart';
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

  const UpdateInfo({
    required this.hasUpdate,
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    required this.htmlUrl,
    this.apkUrl,
    this.setupUrl,
    this.zipUrl,
  });
}

class UpdateService {
  static const String currentVersion = '1.3.8';
  static const String _releasesApiUrl =
      'https://api.github.com/repos/Boci0/Pear-Music/releases/latest';

  static Future<UpdateInfo?> checkLatestRelease() async {
    try {
      final client = HttpClient();
      client.userAgent = 'PearMusicApp/$currentVersion';
      final request = await client.getUrl(Uri.parse(_releasesApiUrl));
      final response = await request.close().timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final tagName = (json['tag_name'] as String? ?? '').trim();
        final htmlUrl = (json['html_url'] as String? ??
            'https://github.com/Boci0/Pear-Music/releases');
        final bodyText = (json['body'] as String? ?? 'No release notes provided.').trim();

        String? apkUrl;
        String? setupUrl;
        String? zipUrl;
        final assets = json['assets'] as List<dynamic>? ?? [];
        for (final asset in assets) {
          if (asset is Map<String, dynamic>) {
            final downloadUrl = asset['browser_download_url'] as String? ?? '';
            if (downloadUrl.endsWith('.apk')) {
              if (downloadUrl.contains('arm64')) {
                apkUrl = downloadUrl;
              } else {
                apkUrl ??= downloadUrl;
              }
            } else if (downloadUrl.endsWith('.exe')) {
              setupUrl = downloadUrl;
            } else if (downloadUrl.endsWith('.zip')) {
              zipUrl = downloadUrl;
            }
          }
        }

        final cleanLatest = _cleanVersion(tagName);
        final hasNewer = _isNewerVersion(currentVersion, cleanLatest);

        return UpdateInfo(
          hasUpdate: hasNewer,
          currentVersion: currentVersion,
          latestVersion: cleanLatest.isEmpty ? currentVersion : cleanLatest,
          releaseNotes: bodyText,
          htmlUrl: htmlUrl,
          apkUrl: apkUrl,
          setupUrl: setupUrl,
          zipUrl: zipUrl,
        );
      }
    } catch (e) {
      debugPrint('[UpdateService] Check failed: $e');
    }
    return null;
  }

  static String _cleanVersion(String tag) {
    return tag.replaceAll(RegExp(r'[^0-9\.]'), '');
  }

  static bool _isNewerVersion(String current, String latest) {
    if (latest.isEmpty) return false;
    final currParts = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final lateParts = latest.split('.').map((e) => int.tryParse(e) ?? 0).toList();

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

  static Future<void> downloadAndApplyWindowsZip(
    BuildContext context,
    String zipUrl,
  ) async {
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

        final exePath = Platform.resolvedExecutable;
        final appDir = p.dirname(exePath);

        final batchScript = File(p.join(tempDir.path, 'peerm_updater.bat'));
        await batchScript.writeAsString('''
@echo off
timeout /t 2 /nobreak > NUL
powershell -Command "Expand-Archive -Path '${zipFile.path}' -DestinationPath '$appDir' -Force"
start "" "$exePath"
del "${zipFile.path}"
(goto) 2>nul & del "%~f0"
''');

        await Process.start(
          'cmd.exe',
          ['/c', batchScript.path],
          mode: ProcessStartMode.detached,
        );

        exit(0);
      } else {
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text('Download failed (HTTP ${response.statusCode})')),
        );
      }
    } catch (e) {
      debugPrint('[UpdateService] Native ZIP update failed: $e');
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Automatic update failed: $e')),
      );
    }
  }

  static Future<void> downloadAndApplyAndroidApk(
    BuildContext context,
    String apkUrl,
  ) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    scaffoldMessenger.showSnackBar(
      const SnackBar(
        content: Text('Downloading APK update...'),
        duration: Duration(seconds: 10),
      ),
    );

    try {
      final cacheDir = await getTemporaryDirectory();
      final apkFile = File(p.join(cacheDir.path, 'peerm_update.apk'));
      if (await apkFile.exists()) await apkFile.delete();

      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(apkUrl));
      final response = await request.close();

      if (response.statusCode == 200) {
        final sink = apkFile.openWrite();
        await response.pipe(sink);
        await sink.close();

        scaffoldMessenger.hideCurrentSnackBar();
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Download complete. Launching installer... If prompted, allow "Install unknown apps" for Pear Music in Settings.',
            ),
            duration: Duration(seconds: 5),
          ),
        );

        final installed = await installApk(apkFile.path);
        if (!installed) {
          final uri = Uri.parse(apkUrl);
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      } else {
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text('Download failed (HTTP ${response.statusCode})')),
        );
      }
    } catch (e) {
      debugPrint('[UpdateService] Native APK update failed: $e');
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Automatic update failed: $e')),
      );
      try {
        final uri = Uri.parse(apkUrl);
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }
}

class _UpdateDialog extends StatelessWidget {
  final UpdateInfo info;
  const _UpdateDialog({required this.info});

  Future<void> _handleUpdate(BuildContext context) async {
    if (defaultTargetPlatform == TargetPlatform.windows && info.zipUrl != null) {
      Navigator.pop(context);
      await UpdateService.downloadAndApplyWindowsZip(context, info.zipUrl!);
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.android && info.apkUrl != null) {
      Navigator.pop(context);
      await UpdateService.downloadAndApplyAndroidApk(context, info.apkUrl!);
      return;
    }

    String targetUrl = info.htmlUrl;
    if (defaultTargetPlatform == TargetPlatform.android && info.apkUrl != null) {
      targetUrl = info.apkUrl!;
    } else if (defaultTargetPlatform == TargetPlatform.windows) {
      if (info.setupUrl != null) {
        targetUrl = info.setupUrl!;
      }
    }

    try {
      final uri = Uri.parse(targetUrl);
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
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
    final isAndroidWithApk = defaultTargetPlatform == TargetPlatform.android && info.apkUrl != null;
    final isWindowsWithZip = defaultTargetPlatform == TargetPlatform.windows && info.zipUrl != null;

    String buttonLabel = 'Get Update';
    if (isAndroidWithApk || isWindowsWithZip) {
      buttonLabel = 'Update In-App';
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
          if (isAndroidWithApk) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'If prompted during install, allow "Install unknown apps" for Pear Music in your Android Settings.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Later'),
        ),
        FilledButton.icon(
          onPressed: () => _handleUpdate(context),
          icon: Icon(isWindowsWithZip || isAndroidWithApk
              ? Icons.system_update
              : Icons.file_download),
          label: Text(buttonLabel),
        ),
      ],
    );
  }
}
