import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/youtube_service.dart';
import '../services/ytdlp_bundle.dart';
import 'tactile_button.dart';

/// The line shown to the user for the outcome of an update or bundle import.
String audioEngineResultMessage(YtDlpUpdateResult result) {
  final v = result.version;
  switch (result.status) {
    case YtDlpUpdateStatus.updated:
      return v == null ? 'yt-dlp updated.' : 'yt-dlp updated to $v.';
    case YtDlpUpdateStatus.upToDate:
      return v == null || v.isEmpty
          ? 'yt-dlp is already up to date.'
          : 'yt-dlp $v is already up to date.';
    case YtDlpUpdateStatus.noSource:
      return 'No update source could be reached. Try again later, or import a '
          'bundle file.';
    case YtDlpUpdateStatus.notManaged:
      return 'This yt-dlp is managed by you or your system, so Pear Music '
          'leaves it alone. Update it with its own tool.';
    case YtDlpUpdateStatus.noBinary:
      return 'There is no yt-dlp on this device yet.';
    case YtDlpUpdateStatus.invalid:
      return 'That file is not a valid, signed yt-dlp bundle.';
    case YtDlpUpdateStatus.wrongPlatform:
      return 'That bundle is for a different operating system.';
    case YtDlpUpdateStatus.failed:
      return 'Something went wrong. Check the debug log for details.';
  }
}

/// Settings card for the desktop yt-dlp: shows which one is in use and offers
/// the ways to keep it working if the usual download sources are unavailable.
class AudioEngineCard extends StatefulWidget {
  const AudioEngineCard({super.key});

  @override
  State<AudioEngineCard> createState() => _AudioEngineCardState();
}

class _AudioEngineCardState extends State<AudioEngineCard> {
  late Future<YtDlpInUse> _inUse = YoutubeService.describeYtDlpInUse();
  bool _busy = false;

  void _refresh() => setState(() => _inUse = YoutubeService.describeYtDlpInUse());

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  String _subtitle(YtDlpInUse info) {
    final version = info.version == null ? '' : ' ${info.version}';
    switch (info.origin) {
      case YtDlpOrigin.none:
        return 'Not found. It downloads automatically when you first play online audio.';
      case YtDlpOrigin.appManaged:
        return 'yt-dlp$version, kept up to date by Pear Music';
      case YtDlpOrigin.custom:
        return 'yt-dlp$version, the file you chose';
      case YtDlpOrigin.system:
        return 'yt-dlp$version, installed on this PC';
    }
  }

  Future<void> _checkForUpdate() => _run(() async {
        _say(audioEngineResultMessage(await YoutubeService.updateYtDlp()));
      });

  Future<void> _importBundle() => _run(() async {
        final picked = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: [YtDlpBundle.fileExtension],
          dialogTitle: 'Import yt-dlp bundle',
        );
        final path = picked.isEmpty ? null : picked.first.path;
        if (path == null) return;
        _say(audioEngineResultMessage(
            await YoutubeService.importYtDlpBundle(File(path))));
      });

  Future<void> _exportBundle() => _run(() async {
        final built = await YoutubeService.buildYtDlpBundle();
        final bytes = built.bytes;
        if (bytes == null) {
          _say(built.error ?? 'Could not export the bundle.');
          return;
        }
        final saved = await FilePicker.saveFile(
          dialogTitle: 'Export yt-dlp bundle',
          fileName: 'pearmusic-resolver.${YtDlpBundle.fileExtension}',
          bytes: bytes,
        );
        if (saved != null) _say('Exported the yt-dlp bundle.');
      });

  Future<void> _chooseOwn() => _run(() async {
        final picked = await FilePicker.pickFiles(
          type: FileType.any,
          dialogTitle: 'Choose your yt-dlp',
        );
        final path = picked.isEmpty ? null : picked.first.path;
        if (path == null) return;
        final version = await YoutubeService.setCustomYtDlpPath(path);
        _say(version == null
            ? 'That file did not run as yt-dlp, so it was not used.'
            : 'Using your yt-dlp $version.');
      });

  Future<void> _useAutomatic() => _run(() async {
        await YoutubeService.setCustomYtDlpPath(null);
        _say('Back to automatic yt-dlp.');
      });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder<YtDlpInUse>(
        future: _inUse,
        builder: (context, snapshot) {
          final info = snapshot.data;
          final enabled = !_busy;
          return Column(
            children: [
              ListTile(
                leading: const Icon(Icons.graphic_eq_rounded),
                title: const Text('Audio engine'),
                subtitle: Text(info == null ? 'Checking…' : _subtitle(info)),
                trailing: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.system_update_alt_rounded),
                title: const Text('Check for engine update'),
                subtitle: const Text('Looks for a newer, signed build'),
                enabled: enabled,
                onTap: () {
                  TactileFeedback.click();
                  _checkForUpdate();
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.file_open_rounded),
                title: const Text('Import engine bundle'),
                subtitle: const Text(
                    'Install a signed .pmyd file from a USB stick or a friend'),
                enabled: enabled,
                onTap: () {
                  TactileFeedback.click();
                  _importBundle();
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.ios_share_rounded),
                title: const Text('Export engine bundle'),
                subtitle: const Text('Save this engine as a file you can share'),
                enabled: enabled,
                onTap: () {
                  TactileFeedback.click();
                  _exportBundle();
                },
              ),
              const Divider(height: 1),
              if (info?.origin == YtDlpOrigin.custom)
                ListTile(
                  leading: const Icon(Icons.restart_alt_rounded),
                  title: const Text('Go back to automatic'),
                  subtitle: Text(info?.path ?? ''),
                  enabled: enabled,
                  onTap: () {
                    TactileFeedback.click();
                    _useAutomatic();
                  },
                )
              else
                ListTile(
                  leading: const Icon(Icons.folder_open_rounded),
                  title: const Text('Use my own yt-dlp'),
                  subtitle: const Text('Pick a yt-dlp file you manage yourself'),
                  enabled: enabled,
                  onTap: () {
                    TactileFeedback.click();
                    _chooseOwn();
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}
