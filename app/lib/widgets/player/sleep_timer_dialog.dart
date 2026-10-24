import 'dart:async';

import '../../theme/glass.dart';
import 'package:flutter/material.dart';

import '../../services/player_service.dart';
import '../pear_popup.dart';
import '../pear_sheet.dart';
import '../tactile_button.dart';

/// Modal dialog allowing the user to select or cancel a sleep timer.
Future<void> showSleepTimerDialog(
  BuildContext context,
  PlayerService player,
) async {
  await showPearPopup<void>(
    context: context,
    showDragHandle: true,
    maxWidth: 420,
    maxHeightFactor: 0.9,
    builder: (context) {
      return ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          return _sheet(context, player);
        },
      );
    },
  );
}

/// The timers as chips, the running one filled.
// The Off chip is the old Turn Off; the running timer shows as its subtitle.
Widget _sheet(BuildContext context, PlayerService player) {
  final remaining = player.sleepTimerRemaining;
  final active = player.isSleepTimerActive;
  final minutes = player.sleepTimerEndOfSong || player.sleepTimerEndOfQueue
      ? null
      : (remaining?.inMinutes ?? 0) + 1;
  Widget chip(String label, VoidCallback set, {bool selected = false}) =>
      PearSheetChip(
        label: label,
        selected: selected,
        onTap: () {
          TactileFeedback.selection();
          set();
          Navigator.pop(context);
        },
      );
  return SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PearSheetTitle(
            'Sleep timer',
            subtitle: !active
                ? null
                : player.sleepTimerEndOfSong
                    ? 'Stopping playback at the end of this song'
                    : player.sleepTimerEndOfQueue
                        ? 'Stopping playback at the end of the queue'
                        : 'Stopping playback in $minutes minutes',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                chip('Off', player.cancelSleepTimer, selected: !active),
                for (final m in const [15, 30, 45])
                  chip('$m min', () => player.setSleepTimer(Duration(minutes: m))),
                chip('1 hour', () => player.setSleepTimer(const Duration(hours: 1))),
                chip(
                  'End of song',
                  () => player.setSleepTimer(null, endOfSong: true),
                  selected: player.sleepTimerEndOfSong,
                ),
                chip(
                  'End of queue',
                  () => player.setSleepTimer(null, endOfQueue: true),
                  selected: player.sleepTimerEndOfQueue,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
}

/// A compact button/chip that shows timer status and remaining countdown.
class SleepTimerButton extends StatefulWidget {
  final PlayerService player;
  const SleepTimerButton({super.key, required this.player});

  @override
  State<SleepTimerButton> createState() => _SleepTimerButtonState();
}

class _SleepTimerButtonState extends State<SleepTimerButton> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayerChanged);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.player.isSleepTimerActive && mounted) {
        setState(() {});
      }
    });
  }

  void _onPlayerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant SleepTimerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerChanged);
      widget.player.addListener(_onPlayerChanged);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.player.removeListener(_onPlayerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final scheme = Theme.of(context).colorScheme;
    final isActive = player.isSleepTimerActive;
    final remaining = player.sleepTimerRemaining;

    String label = 'Sleep Timer';
    if (isActive) {
      if (player.sleepTimerEndOfSong) {
        label = 'End of song';
      } else if (player.sleepTimerEndOfQueue) {
        label = 'End of queue';
      } else if (remaining != null) {
        final m = remaining.inMinutes;
        final s = remaining.inSeconds % 60;
        label = '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      }
    }

    return TactileIconButton(
      tooltip: isActive ? 'Sleep timer: $label' : 'Set sleep timer',
      icon: isActive
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(PearGlassTokens.r(12)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bedtime_rounded, size: 16, color: scheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            )
          : const Icon(Icons.bedtime_outlined),
      onPressed: () => showSleepTimerDialog(context, player),
    );
  }
}
