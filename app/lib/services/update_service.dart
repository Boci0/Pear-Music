import 'dart:convert';
import 'dart:io';

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
  static const String currentVersion = '1.4.2';
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

  static Future<void> downloadAndInstallAndroidApk(
    BuildContext context,
    String apkUrl,
  ) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
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
      });
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
    if (defaultTargetPlatform == TargetPlatform.windows && info.zipUrl != null) {
      Navigator.pop(context);
      await UpdateService.downloadAndApplyWindowsZip(context, info.zipUrl!);
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.android && info.apkUrl != null) {
      Navigator.pop(context);
      await UpdateService.downloadAndInstallAndroidApk(context, info.apkUrl!);
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
          icon: Icon(isWindowsWithZip ? Icons.system_update : Icons.file_download),
          label: Text(buttonLabel),
        ),
      ],
    );
  }
}
