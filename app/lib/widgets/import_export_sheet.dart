import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../services/youtube_service.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';
import 'pear_popup.dart';
import 'tactile_button.dart';

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

    Widget sectionLabel(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(
            PearSpacing.xl,
            PearSpacing.lg,
            PearSpacing.xl,
            PearSpacing.sm,
          ),
          child: Text(
            text.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: muted,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w600,
            ),
          ),
        );

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: PearSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PearSpacing.xl,
                PearSpacing.md,
                PearSpacing.xl,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Import & export',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: PearSpacing.xs),
                  Text(
                    'Move your music to another device or player.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            sectionLabel('Library backup'),
            _OptionCard(
              key: const ValueKey('import_export_export_library'),
              icon: Icons.ios_share_rounded,
              title: 'Export backup',
              detail: exportDetail,
              enabled: !backupEmpty,
              onTap: () =>
                  Navigator.pop(context, ImportExportAction.exportLibrary),
            ),
            _OptionCard(
              key: const ValueKey('import_export_import_library'),
              icon: Icons.settings_backup_restore_rounded,
              title: 'Restore backup',
              detail: controller.isProfileImporting
                  ? 'A restore is already running'
                  : 'Downloads every song in a backup and restores its hearts',
              enabled: !controller.isProfileImporting,
              onTap: () =>
                  Navigator.pop(context, ImportExportAction.importLibrary),
            ),
            if (summary.localOnly > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  PearSpacing.xl,
                  PearSpacing.xs,
                  PearSpacing.xl,
                  0,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, size: 14, color: muted),
                    const SizedBox(width: PearSpacing.sm),
                    Expanded(
                      child: Text(
                        '${_plural(summary.localOnly, 'song')} added from '
                        'files stay on this device and are not in the backup.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            sectionLabel('Playlists'),
            _OptionCard(
              key: const ValueKey('import_export_import_playlists'),
              icon: Icons.playlist_add_rounded,
              title: 'Import playlists',
              detail: '.m3u or .m3u8 files from Pear Music or any other player',
              enabled: !controller.isPlaylistImporting,
              onTap: () =>
                  Navigator.pop(context, ImportExportAction.importPlaylists),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PearSpacing.xl,
                PearSpacing.xs,
                PearSpacing.xl,
                0,
              ),
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

/// One tappable option: a tinted icon, a title and a line saying exactly
/// what happens.
class _OptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final bool enabled;
  final VoidCallback onTap;

  const _OptionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final card = Container(
      padding: const EdgeInsets.all(PearSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: PearGlassTokens.cardFill),
        borderRadius: PearRadius.rowAll,
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.14),
              borderRadius: PearRadius.rowAll,
            ),
            child: Icon(icon, color: scheme.primary, size: 22),
          ),
          const SizedBox(width: PearSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: PearSpacing.sm),
          Icon(
            Icons.chevron_right_rounded,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: PearSpacing.lg,
        vertical: PearSpacing.xs,
      ),
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: TactileBounce(
          scaleDown: 0.97,
          borderRadius: PearRadius.rowAll,
          onTap: enabled ? onTap : null,
          child: Semantics(button: true, enabled: enabled, child: card),
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
    return AlertDialog(
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
