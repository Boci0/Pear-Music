import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../widgets/pear_app_bar.dart';
import '../widgets/song_tile.dart';
import '../widgets/tactile_button.dart';

/// History tab: every song that started playing, newest first, local files and
/// online streams mixed together in one list.
///
/// The list is intentionally plain (no filters, no grouping) and reuses
/// [SongTile], so rows cost the same as the library ones.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  Future<void> _confirmClear(
    BuildContext context,
    AppController controller,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear listening history?'),
        content: const Text(
          'This only clears the history list. Your songs, favorites and '
          'playlists are untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) {
      TactileFeedback.selection();
      await controller.clearHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final songs = controller.historySongs;
    final currentSongId = controller.player.currentSong?.id;

    return Scaffold(
      appBar: PearAppBar(
        label: 'History',
        actions: [
          if (songs.isNotEmpty)
            TactileIconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear history',
              onPressed: () => _confirmClear(context, controller),
            ),
        ],
      ),
      body: songs.isEmpty
          ? const _EmptyHistory()
          : CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.only(top: 8, bottom: 140),
                  sliver: SliverFixedExtentList.builder(
                    itemExtent: 61.0,
                    itemCount: songs.length,
                    findChildIndexCallback: (Key key) {
                      final valueKey = key as ValueKey<String>?;
                      if (valueKey == null) return null;
                      final index =
                          songs.indexWhere((s) => s.id == valueKey.value);
                      return index >= 0 ? index : null;
                    },
                    itemBuilder: (context, i) {
                      final song = songs[i];
                      return RepaintBoundary(
                        child: SongTile(
                          key: ValueKey(song.id),
                          song: song,
                          queue: songs,
                          sourceId: 'history',
                          sourceTitle: 'History',
                          isCurrent: currentSongId == song.id,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: primary.withValues(alpha: 0.25),
                  width: 1,
                ),
              ),
              child: Icon(
                Icons.history_rounded,
                size: 36,
                color: primary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Nothing played yet',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Songs you play show up here, newest first, including your '
              'local files and online streams.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
