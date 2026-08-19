import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/sync_service.dart';

/// Shows in-flight uploads/downloads in a single unified sync card.
class TransferList extends StatefulWidget {
  const TransferList({super.key});

  @override
  State<TransferList> createState() => _TransferListState();
}

class _TransferListState extends State<TransferList> {
  double _lastMaxFraction = 0.0;

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
    final activeFraction = batch.progressFraction;

    if (completedSongs == 0 && activeFraction == 0.0) {
      _lastMaxFraction = activeFraction;
    } else if (activeFraction > _lastMaxFraction) {
      _lastMaxFraction = activeFraction;
    }
    final overallFraction = batch.isDone ? 1.0 : _lastMaxFraction.clamp(0.0, 1.0);

    final isSingle = totalSongs <= 1;
    final headerTitle = batch.isDone
        ? 'Sync Complete'
        : (isSingle
            ? (batch.isDownload ? 'Downloading Song' : 'Uploading Song')
            : 'Syncing Library ($completedSongs of $totalSongs songs)');

    final completedMb = (batch.completedBytes / (1024 * 1024)).toStringAsFixed(1);
    final totalMb = (batch.totalBytes / (1024 * 1024)).toStringAsFixed(1);
    final displayedMb = batch.totalBytes > 0
        ? '$completedMb MB / $totalMb MB'
        : (batch.activeTotalBytes > 0
            ? '${(batch.activeBytes / (1024 * 1024)).toStringAsFixed(1)} MB / ${(batch.activeTotalBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
            : '');

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
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
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
                    '${(overallFraction * 100).toInt()}%',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: batch.isDone
                              ? Colors.greenAccent.shade400
                              : Theme.of(context).colorScheme.primary,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: overallFraction),
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                builder: (context, val, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: val,
                    minHeight: 6,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      batch.isDone
                          ? Colors.greenAccent.shade400
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
              if (!batch.isDone && batch.activeSongTitle.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
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
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey,
                            ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
