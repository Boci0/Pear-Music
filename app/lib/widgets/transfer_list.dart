import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/sync_service.dart';

/// Shows in-flight uploads/downloads with a live progress bar.
///
/// This is the ONLY widget that subscribes to SyncService's high-frequency
/// transfer ticks. It is deliberately self-contained so a syncing file does
/// not rebuild the rest of the library screen.
class TransferList extends StatelessWidget {
  const TransferList({super.key});

  @override
  Widget build(BuildContext context) {
    final transfers = context.watch<SyncService>().transfers;
    if (transfers.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'Syncing',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary),
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

/// One row in the sync list. Animated: the progress bar moves smoothly while a
/// transfer is in flight, and when it completes the icon pops into a green
/// check with an ease-out-back scale before the row disappears (the finished
/// transfer is retained briefly by [SyncService] so this moment is visible).
class _TransferTileState extends State<_TransferTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _scale = CurvedAnimation(parent: _controller, curve: Curves.easeOutBack);
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
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
    final progress = widget.progress;
    final done = progress.isDone;
    final color = done ? Colors.green : theme.colorScheme.secondary;
    final icon = done
        ? Icons.check_circle
        : (progress.isDownload ? Icons.download : Icons.upload);
    final label =
        done ? 'Complete' : (progress.isDownload ? 'Receiving' : 'Sending');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ScaleTransition(
                scale: _scale,
                child: FadeTransition(
                  opacity: _fade,
                  child: Icon(icon, size: 16, color: color),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${progress.fileName} · $label',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: done ? Colors.green : null,
                    fontWeight: done ? FontWeight.w600 : null,
                  ),
                ),
              ),
              Text(
                done ? 'Done' : '${(progress.fraction * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: done ? Colors.green : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: done ? 1 : progress.fraction,
              minHeight: 4,
              color: done ? Colors.green : null,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}
