import 'package:flutter/material.dart';

import '../../services/player_service.dart';

/// Modal bottom sheet allowing the user to select playback speed.
Future<void> showPlaybackSpeedDialog(
  BuildContext context,
  PlayerService player,
) async {
  const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      final currentSpeed = player.speed;

      return SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.speed_rounded, color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Playback Speed',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  if ((currentSpeed - 1.0).abs() > 0.01)
                    TextButton(
                      onPressed: () {
                        player.setSpeed(1.0);
                        Navigator.pop(context);
                      },
                      child: const Text('Reset'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              ...speeds.map((s) {
                final isSelected = (currentSpeed - s).abs() < 0.01;
                final label = s == 1.0 ? '1.0x (Normal)' : '${s}x';

                return ListTile(
                  dense: true,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  selected: isSelected,
                  selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.35),
                  title: Text(
                    label,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? scheme.primary : scheme.onSurface,
                    ),
                  ),
                  trailing: isSelected
                      ? Icon(Icons.check_rounded, color: scheme.primary)
                      : null,
                  onTap: () {
                    player.setSpeed(s);
                    Navigator.pop(context);
                  },
                );
              }),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
    },
  );
}

/// Compact button for the player top bar displaying current speed.
class PlaybackSpeedButton extends StatelessWidget {
  final PlayerService player;

  const PlaybackSpeedButton({super.key, required this.player});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final speed = player.speed;
        final isCustomSpeed = (speed - 1.0).abs() > 0.01;
        final scheme = Theme.of(context).colorScheme;

        return IconButton(
          tooltip: isCustomSpeed ? 'Playback speed: ${speed}x' : 'Playback speed',
          icon: isCustomSpeed
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${speed}x',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                )
              : const Icon(Icons.speed_rounded),
          onPressed: () => showPlaybackSpeedDialog(context, player),
        );
      },
    );
  }
}
