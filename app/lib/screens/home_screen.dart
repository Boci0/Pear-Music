import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/youtube_service.dart';
import '../widgets/song_tile.dart';
import '../widgets/transfer_list.dart';
import 'playlists_screen.dart';

/// Library tab: drag & drop (Windows) or picker, then play.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final songs = controller.songs;

    final content = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        const SliverToBoxAdapter(child: TransferList()),
        if (songs.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyState(onAdd: () => controller.addFilesFromPicker()),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.only(bottom: 24),
            sliver: SliverList.builder(
              itemCount: songs.length,
              itemBuilder: (context, i) {
                final song = songs[i];
                return SongTile(
                  song: song,
                  isCurrent: controller.player.currentSong?.id == song.id,
                );
              },
            ),
          ),
      ],
    );

    Widget body = content;
    if (_isDesktop) {
      body = DropTarget(
        onDragDone: (details) {
          controller.addDroppedFiles(
            details.files.map((f) => File(f.path)).toList(),
          );
        },
        child: content,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Image.asset(
          'assets/pear_logo.png',
          width: 36,
          height: 36,
          filterQuality: FilterQuality.medium,
        ),
        actions: [
          // On mobile, a compact status dot keeps the app bar uncluttered so
          // the pear title keeps its full size (the chips would crowd it and
          // squeeze the image down on narrow screens). Desktop keeps the chips.
          if (_isDesktop)
            _ConnectionChip(status: controller.connectionStatus)
          else
            _ConnectionDot(status: controller.connectionStatus),
          if (controller.pairedDevices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Chip(
                avatar: const Icon(Icons.devices, size: 16),
                label: Text(
                    '${controller.pairedDevices.length} paired'),
                visualDensity: VisualDensity.compact,
              ),
            ),
          IconButton(
            tooltip: 'Add from YouTube / Spotify',
            icon: const Icon(Icons.add_link),
            onPressed: () => _openYouTubeDialog(context),
          ),
          IconButton(
            tooltip: 'Playlists',
            icon: const Icon(Icons.queue_music),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlaylistsScreen()),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: body,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => controller.addFilesFromPicker(),
        icon: const Icon(Icons.library_music),
        label: const Text('Add music'),
      ),
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  final String status;
  const _ConnectionChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      'connected' => (Colors.green, 'Online'),
      'connecting' => (Colors.orange, 'Connecting…'),
      _ => (Colors.grey, 'Offline'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Chip(
        avatar: Icon(Icons.circle, size: 10, color: color),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// Compact connection indicator for narrow/mobile app bars (a plain colored
/// dot instead of a full chip, so the title is never squeezed out).
class _ConnectionDot extends StatelessWidget {
  final String status;
  const _ConnectionDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'connected' => Colors.green,
      'connecting' => Colors.orange,
      _ => Colors.grey,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Center(
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.library_music_outlined,
                size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Your music library is empty',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Tap "Add music" to pick audio files.\nOn Windows you can also drag & drop files here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add music'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openYouTubeDialog(BuildContext context) async {
  final controller = context.read<AppController>();
  await showDialog<void>(
    context: context,
    builder: (_) => _YouTubeDialog(controller: controller),
  );
}

/// Paste a YouTube link, watch it download straight to this device, then let
/// the sync engine push it to paired peers.
class _YouTubeDialog extends StatefulWidget {
  final AppController controller;
  const _YouTubeDialog({required this.controller});

  @override
  State<_YouTubeDialog> createState() => _YouTubeDialogState();
}

class _YouTubeDialogState extends State<_YouTubeDialog> {
  final _urlController = TextEditingController();
  final _cancel = DownloadCancellation();
  bool _busy = false;
  String _status = '';
  String? _error;
  int _downloaded = 0;
  int _total = 0;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  String _bytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _start() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _status = 'Starting…';
      _error = null;
      _downloaded = 0;
      _total = 0;
    });
    final error = await widget.controller.addFromLink(
      url,
      cancel: _cancel,
      onStatus: (s) {
        if (mounted) {
          setState(() => _status = s);
        }
      },
      onProgress: (downloaded, total) {
        // Throttle to ~12 updates/sec: every chunk (64KB) triggers this, and
        // rebuilding the dialog on each one is what made the progress bar lag
        // on the phone. Always show the final 100% state.
        final now = DateTime.now();
        final done = total > 0 && downloaded >= total;
        if (!done &&
            now.difference(_lastProgress).inMilliseconds < 80) {
          return;
        }
        _lastProgress = now;
        if (mounted) {
          setState(() {
            _downloaded = downloaded;
            _total = total;
          });
        }
      },
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      // Show the failure inline so the user can see why it stopped and retry.
      setState(() {
        _busy = false;
        _status = '';
        _error = error;
        _downloaded = 0;
        _total = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      // Everything (title, field, helper, progress, actions) lives inside a
      // SingleChildScrollView so the dialog can NEVER overflow: when the soft
      // keyboard shrinks the window in landscape, the content simply scrolls
      // instead of a RenderFlex overflowing. (AlertDialog's `scrollable` only
      // scrolls title + content, NOT the actions bar - which is the column
      // that overflowed on the phone by 23px.)
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Add from link',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _urlController,
                autofocus: true,
                keyboardType: TextInputType.url,
                enabled: !_busy,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _start(),
                decoration: const InputDecoration(
                  labelText: 'YouTube or Spotify link',
                  hintText:
                      'https://www.youtube.com/watch?v=…  or  …/spotify.com/track/…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'YouTube links download the audio straight to this device. Spotify '
                'links are matched to their YouTube source (Spotify audio is '
                'DRM-protected), so either way it syncs to your paired devices '
                'with artwork.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _total > 0
                        ? (_downloaded / _total).clamp(0.0, 1.0)
                        : null,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (_total > 0)
                      Text(
                        '${_bytes(_downloaded)} / ${_bytes(_total)} '
                        '(${(_downloaded / _total * 100).clamp(0, 100).toStringAsFixed(0)}%)',
                        style: theme.textTheme.labelSmall,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              // Actions live INSIDE the scroll view too, so they can never be
              // pushed off-screen or overflow when vertical space is tight.
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? () {
                            _cancel.cancel();
                            Navigator.of(context).pop();
                          }
                        : () => Navigator.of(context).pop(),
                    child: Text(_busy ? 'Cancel download' : 'Cancel'),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _start,
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Download'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
