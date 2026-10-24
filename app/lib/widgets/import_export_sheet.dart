import 'pear_sheet.dart';
import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../services/youtube_service.dart';
import '../theme/tokens.dart';
import 'pear_popup.dart';

/// What the user picked on the import & export sheet.
enum ImportExportAction { exportLibrary, importLibrary, importPlaylists }

/// Opens the import & export sheet: one place for the library backup and
/// playlist files, each option spelling out what it moves. Returns the
/// picked action, or null when the sheet was dismissed.
Future<ImportExportAction?> showImportExportSheet(
  BuildContext context,
  AppController controller, {
  Offset? anchor,
}) {
  return showPearPopup<ImportExportAction>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    maxWidth: 420,
    anchor: anchor,
    anchorAlignRight: true,
    builder: (_) => _ImportExportSheet(controller: controller),
  );
}

class _ImportExportSheet extends StatelessWidget {
  final AppController controller;

  const _ImportExportSheet({required this.controller});

  static String _plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final summary = controller.libraryBackupSummary;
    final hearts = summary.favorites + summary.onlineFavorites;
    final backupEmpty = summary.songs == 0 && summary.onlineFavorites == 0;

    final exportDetail = backupEmpty
        ? 'Nothing to back up yet: add songs from links or heart online songs'
        : [
            _plural(summary.songs, 'song'),
            if (hearts > 0) _plural(hearts, 'favorite'),
          ].join(' · ');

    // shortcut: the board's in-sheet progress card is not built; imports
    // keep their own progress dialog.
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: PearSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PearSheetTitle('Import and export'),
            const PearSheetLabel('Backup'),
            PearSheetRow(
              key: const ValueKey('import_export_export_library'),
              label: 'Export backup',
              detail: exportDetail,
              onTap: backupEmpty
                  ? null
                  : () => Navigator.pop(
                        context,
                        ImportExportAction.exportLibrary,
                      ),
            ),
            PearSheetRow(
              key: const ValueKey('import_export_import_library'),
              label: 'Restore backup',
              detail: controller.isProfileImporting
                  ? 'A restore is already running'
                  : 'Downloads every song in a backup and restores its hearts',
              onTap: controller.isProfileImporting
                  ? null
                  : () => Navigator.pop(
                        context,
                        ImportExportAction.importLibrary,
                      ),
            ),
            if (summary.localOnly > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                  '${_plural(summary.localOnly, 'song')} added from files '
                  'stay on this device and are not in the backup.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
            const PearSheetLabel('Bring in'),
            PearSheetRow(
              key: const ValueKey('import_export_import_playlists'),
              label: 'Import playlists',
              detail:
                  '.m3u or .m3u8 files from Pear Music or any other player',
              onTap: controller.isPlaylistImporting
                  ? null
                  : () => Navigator.pop(
                        context,
                        ImportExportAction.importPlaylists,
                      ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                'To export a playlist, open its ⋮ menu in the Playlists tab.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks playlist files and imports them behind a progress dialog with a
/// Cancel button, so matching a long list never looks frozen.
Future<void> showPlaylistImportDialog(
  BuildContext context,
  AppController controller,
) {
  if (controller.isPlaylistImporting) return Future.value();
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PlaylistImportDialog(controller: controller),
  );
}

class _PlaylistImportDialog extends StatefulWidget {
  final AppController controller;

  const _PlaylistImportDialog({required this.controller});

  @override
  State<_PlaylistImportDialog> createState() => _PlaylistImportDialogState();
}

class _PlaylistImportDialogState extends State<_PlaylistImportDialog> {
  final DownloadCancellation _cancel = DownloadCancellation();
  String _status = 'Choosing playlist files…';
  int _done = 0;
  int _total = 0;
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final navigator = Navigator.of(context);
    await widget.controller.importPlaylistsFromM3u(
      cancel: _cancel,
      onStatus: (status) {
        _status = status;
        _refresh();
      },
      onProgress: (done, total) {
        _done = done;
        _total = total;
        _refresh(force: done == 0 || done == total);
      },
    );
    if (mounted) navigator.pop();
  }

  /// Local matches resolve in microseconds; cap repaints at ~12 a second.
  void _refresh({bool force = false}) {
    if (!mounted) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastUiUpdate).inMilliseconds < 80) return;
    _lastUiUpdate = now;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PearAlertDialog(
      title: const Text('Importing playlists'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_status, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: PearSpacing.md),
          ClipRRect(
            borderRadius: PearRadius.pillAll,
            child: LinearProgressIndicator(
              minHeight: 6,
              value: _total > 0 ? _done / _total : null,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _total > 0 ? '$_done of $_total songs' : 'Reading files…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _cancel.isCancelled
              ? null
              : () => setState(_cancel.cancel),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
