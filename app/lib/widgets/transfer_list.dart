import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/sync_service.dart';

class TransferList extends StatelessWidget {
  const TransferList({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final batch = sync.batchState;

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      child: batch == null
          ? const SizedBox.shrink()
          : _buildCard(context, sync, batch),
    );
  }

  Widget _buildCard(
      BuildContext context, SyncService sync, SyncBatchState batch) {
    final totalSongs = batch.totalSongs;
    final completedSongs = batch.completedSongs;
    final overallFraction = batch.progressFraction;

    final isSingle = totalSongs <= 1;
    final headerTitle = batch.isDone
        ? (completedSongs < totalSongs || totalSongs == 0
            ? 'Sync Incomplete ($completedSongs of $totalSongs songs)'
            : 'Sync Complete')
        : (isSingle
            ? (batch.isDownload ? 'Downloading Song' : 'Uploading Song')
            : 'Syncing Library ($completedSongs of $totalSongs songs)');

    // ONE animated value drives the bar, the percent text AND the MB counter,
    // so all three glide together instead of the numbers stuttering while the
    // bar animates. Raw progress arrives in bursts (relay ack pacing + notify
    // throttling); interpolating over ~400ms makes the display read smoothly.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: overallFraction),
      duration: Duration(milliseconds: batch.isDone ? 150 : 400),
      curve: batch.isDone ? Curves.easeOut : Curves.linear,
      builder: (context, val, _) {
        final displayFraction = val.clamp(0.0, 1.0);

        final String displayedMb;
        if (batch.totalBytes > 0) {
          final currentBytes = displayFraction * batch.totalBytes;
          displayedMb =
              '${(currentBytes / (1024 * 1024)).toStringAsFixed(1)} MB / '
              '${(batch.totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
        } else if (batch.activeTotalBytes > 0) {
          final currentBytes = displayFraction * batch.activeTotalBytes;
          displayedMb =
              '${(currentBytes / (1024 * 1024)).toStringAsFixed(1)} MB / '
              '${(batch.activeTotalBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
        } else {
          displayedMb = '';
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        batch.isDone
                            ? Icons.check_circle_rounded
                            : (batch.isDownload
                                ? Icons.download_rounded
                                : Icons.upload_rounded),
                        size: 20,
                        color: batch.isDone
                            ? Colors.greenAccent.shade400
                            : Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          headerTitle,
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                        ),
                      ),
                      if (!batch.isDone) ...[
                        const SizedBox(width: 4),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: 'Retry sync',
                          icon: const Icon(Icons.refresh, size: 16),
                          onPressed: () => sync.resyncNow(),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        '${(displayFraction * 100).toInt()}%',
                        style:
                            Theme.of(context).textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: batch.isDone
                                      ? Colors.greenAccent.shade400
                                      : Theme.of(context).colorScheme.primary,
                                ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: displayFraction,
                      minHeight: 6,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        batch.isDone
                            ? Colors.greenAccent.shade400
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  // Fade/slide between songs instead of hard pop-in/pop-out.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.25),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: (!batch.isDone && batch.activeSongTitle.isNotEmpty)
                        ? Row(
                            key: ValueKey(batch.activeSongTitle),
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  batch.activeSongTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                              if (displayedMb.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Text(
                                  displayedMb,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: Colors.grey),
                                ),
                              ],
                            ],
                          )
                        : const SizedBox(width: double.infinity, height: 0),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}