import 'package:flutter/material.dart';

import '../../theme/glass.dart';
import '../../services/player_service.dart';
import '../pear_popup.dart';
import '../pear_sheet.dart';
import '../tactile_button.dart';

/// Modal bottom sheet allowing the user to select playback speed.
Future<void> showPlaybackSpeedDialog(
  BuildContext context,
  PlayerService player,
) async {
  const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  await showPearPopup<void>(
    context: context,
    showDragHandle: true,
    maxWidth: 420,
    builder: (context) {
      final currentSpeed = player.speed;
      // shortcut: the board's Fine tune slider and 0.5x-2.0x in 5 steps; the
      // player only has these seven speeds, so no slider.
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PearSheetTitle(
                'Speed · ${currentSpeed}x',
                trailing: (currentSpeed - 1.0).abs() > 0.01
                    ? SizedBox(
                        width: 96,
                        child: PearSheetButton(
                          label: 'Reset',
                          height: 36,
                          onTap: () {
                            player.setSpeed(1.0);
                            Navigator.pop(context);
                          },
                        ),
                      )
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in speeds)
                      PearSheetChip(
                        label: '${s}x',
                        selected: (currentSpeed - s).abs() < 0.01,
                        onTap: () {
                          TactileFeedback.selection();
                          player.setSpeed(s);
                          Navigator.pop(context);
                        },
                      ),
                  ],
                ),
              ),
            ],
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

        return TactileIconButton(
          tooltip: isCustomSpeed ? 'Playback speed: ${speed}x' : 'Playback speed',
          icon: isCustomSpeed
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(PearGlassTokens.r(8)),
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
