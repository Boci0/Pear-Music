import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/sync_service.dart';

/// Shows in-flight uploads/downloads with a live progress bar.
///
/// When 1-3 files are syncing, renders individual progress rows. When a large
/// batch is transferring (4+ files), aggregates them into a single clean
/// Unified Batch Sync Card to avoid cluttering the UI with dozens of bars.
class TransferList extends StatefulWidget {
  const TransferList({super.key});

  @override
  State<TransferList> createState() => _TransferListState();
}

class _TransferListState extends State<TransferList> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final transfers = context.watch<SyncService>().transfers;
    if (transfers.isEmpty) return const SizedBox.shrink();

    final isBatch = transfers.length > 3;

    if (isBatch && !_expanded) {
      final totalFiles = transfers.length;
      final doneFiles = transfers.where((t) => t.isDone).length;
      final totalBytes = transfers.fold<int>(0, (sum, t) => sum + t.totalBytes);
      final completedBytes = transfers.fold<int>(0, (sum, t) => sum + t.completedBytes);
      final activeTransfer = transfers.firstWhere((t) => !t.isDone, orElse: () => transfers.last);

      final overallFraction = totalBytes > 0
          ? (completedBytes / totalBytes).clamp(0.0, 1.0)
          : (doneFiles / totalFiles).clamp(0.0, 1.0);

      final completedMb = (completedBytes / (1024 * 1024)).toStringAsFixed(1);
      final totalMb = (totalBytes / (1024 * 1024)).toStringAsFixed(1);

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
                    const Icon(Icons.sync, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Syncing Library ($doneFiles of $totalFiles songs)',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.expand_more, size: 20),
                      tooltip: 'Show details',
                      onPressed: () => setState(() => _expanded = true),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: overallFraction),
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
                      '$completedMb MB / $totalMb MB',
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Syncing',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(color: Theme.of(context).colorScheme.primary),
              ),
              if (isBatch && _expanded)
                IconButton(
                  icon: const Icon(Icons.expand_less, size: 20),
                  tooltip: 'Collapse batch view',
                  onPressed: () => setState(() => _expanded = false),
                ),
            ],
          ),
        ),
        ...transfers.map((t) => _TransferTile(progress: t)),
        const Divider(height: 8),
      ],
    );
  }
}

class _TransferTile extends StatefulWidget {
  final TransferProgress progress;

  const _TransferTile({required this.progress});

  @override
  State<_TransferTile> createState() => _TransferTileState();
}

class _TransferTileState extends State<_TransferTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _scale = CurvedAnimation(parent: _controller, curve: Curves.easeOutBack);
    if (widget.progress.isDone) {
      _controller.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant _TransferTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.progress.isDone && _controller.value < 1) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.progress;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                p.isDownload ? Icons.download_rounded : Icons.upload_rounded,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  if (_controller.value > 0) {
                    return Transform.scale(
                      scale: _scale.value,
                      child: Icon(
                        Icons.check_circle_rounded,
                        size: 18,
                        color: Colors.greenAccent.shade400,
                      ),
                    );
                  }
                  final pct = (p.fraction * 100).toInt();
                  return Text('$pct%', style: theme.textTheme.bodySmall);
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: p.fraction,
              minHeight: 3,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(
                p.isDone ? Colors.greenAccent.shade400 : theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
