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
    final transfers = context.watch<SyncService>().transfers;
    if (transfers.isEmpty) {
      _lastMaxFraction = 0.0;
      return const SizedBox.shrink();
    }

    final totalFiles = transfers.length;
    final doneFiles = transfers.where((t) => t.isDone).length;
    final totalBytes = transfers.fold<int>(0, (sum, t) => sum + t.totalBytes);
    final completedBytes = transfers.fold<int>(0, (sum, t) => sum + t.completedBytes);
    final activeTransfer = transfers.firstWhere((t) => !t.isDone, orElse: () => transfers.last);

    final activeFraction = activeTransfer.isDone ? 1.0 : activeTransfer.fraction;
    final rawOverallFraction = totalFiles > 1
        ? ((doneFiles + activeFraction) / totalFiles).clamp(0.0, 1.0)
        : activeFraction;

    if (doneFiles == 0 && activeFraction == 0.0) {
      _lastMaxFraction = rawOverallFraction;
    } else if (rawOverallFraction > _lastMaxFraction) {
      _lastMaxFraction = rawOverallFraction;
    }
    final overallFraction = _lastMaxFraction.clamp(0.0, 1.0);

    final isSingle = totalFiles == 1;
    final headerTitle = isSingle
        ? (activeTransfer.isDownload ? 'Downloading Song' : 'Uploading Song')
        : 'Syncing Library ($doneFiles of $totalFiles songs)';

    final displayedMb = isSingle
        ? '${(activeTransfer.completedBytes / (1024 * 1024)).toStringAsFixed(1)} MB / ${(activeTransfer.totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '${(completedBytes / (1024 * 1024)).toStringAsFixed(1)} MB / ${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB';

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
                    activeTransfer.isDownload
                        ? Icons.download_rounded
                        : Icons.upload_rounded,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
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
                  Text(
                    '${(overallFraction * 100).toInt()}%',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: overallFraction),
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                builder: (context, val, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: val,
                    minHeight: 6,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      activeTransfer.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    displayedMb,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey,
                        ),
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
