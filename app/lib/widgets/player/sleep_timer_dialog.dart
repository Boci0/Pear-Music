import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/player_service.dart';

/// Modal dialog allowing the user to select or cancel a sleep timer.
Future<void> showSleepTimerDialog(
  BuildContext context,
  PlayerService player,
) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      final remaining = player.sleepTimerRemaining;
      final isActive = player.isSleepTimerActive;

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.bedtime_rounded, color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Sleep Timer',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  if (isActive)
                    TextButton(
                      onPressed: () {
                        player.cancelSleepTimer();
                        Navigator.pop(context);
                      },
                      child: const Text('Turn Off'),
                    ),
                ],
              ),
              if (isActive) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    player.sleepTimerEndOfSong
                        ? 'Stopping playback at the end of this song'
                        : 'Stopping playback in ${(remaining?.inMinutes ?? 0) + 1} minutes',
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _timerTile(
                context,
                title: '15 minutes',
                onTap: () {
                  player.setSleepTimer(const Duration(minutes: 15));
                  Navigator.pop(context);
                },
              ),
              _timerTile(
                context,
                title: '30 minutes',
                onTap: () {
                  player.setSleepTimer(const Duration(minutes: 30));
                  Navigator.pop(context);
                },
              ),
              _timerTile(
                context,
                title: '45 minutes',
                onTap: () {
                  player.setSleepTimer(const Duration(minutes: 45));
                  Navigator.pop(context);
                },
              ),
              _timerTile(
                context,
                title: '1 hour',
                onTap: () {
                  player.setSleepTimer(const Duration(hours: 1));
                  Navigator.pop(context);
                },
              ),
              _timerTile(
                context,
                title: 'End of current song',
                onTap: () {
                  player.setSleepTimer(null, endOfSong: true);
                  Navigator.pop(context);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
    },
  );
}

Widget _timerTile(
  BuildContext context, {
  required String title,
  required VoidCallback onTap,
}) {
  return ListTile(
    dense: true,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    leading: const Icon(Icons.timer_outlined, size: 20),
    title: Text(title),
    onTap: onTap,
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
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.player.isSleepTimerActive && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
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
      } else if (remaining != null) {
        final m = remaining.inMinutes;
        final s = remaining.inSeconds % 60;
        label = '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      }
    }

    return IconButton(
      tooltip: isActive ? 'Sleep timer: $label' : 'Set sleep timer',
      icon: isActive
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bedtime_rounded, size: 16, color: scheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
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
