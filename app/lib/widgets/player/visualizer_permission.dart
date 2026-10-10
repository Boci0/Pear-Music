import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../services/visualizer_feed.dart';

/// Asks for the audio access the Android visualizer needs, and says what it is
/// for first.
///
/// Android only lets an app read its own output spectrum with the same
/// permission as recording from the microphone, so the system prompt reads
/// for the microphone. Nothing here records: the effect is attached to the app's
/// own playback and gives back frequency levels for drawing bars. The
/// explanation exists so that prompt is not taken for something it is not.
class VisualizerPermission {
  VisualizerPermission._();

  static bool _askedThisRun = false;

  /// Whether this platform needs the permission at all.
  static bool get needed => !kIsWeb && Platform.isAndroid;

  /// Called when a visualizer mounts. If the access has not been granted and
  /// the person has never been told what it is for, explains and asks once.
  /// A refusal turns the visualizer off (the Settings switch asks again
  /// later), so a cover never dances to a made-up pattern behind a refusal.
  static Future<void> askOnce(BuildContext context) async {
    if (!needed || _askedThisRun) return;
    final controller = context.read<AppController?>();
    if (controller == null || controller.identity.visualizerAudioExplained) {
      return;
    }
    // Hold the bars still until the question is answered, from the first frame.
    VisualizerFeed.instance.awaitingPermission = true;
    try {
      if (await Permission.microphone.isGranted) return;
      _askedThisRun = true;
      // Wait for the player to finish opening before putting a dialog on it.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!context.mounted) return;
      final granted = await request(context);
      if (granted) {
        VisualizerFeed.instance.restartCapture();
      } else {
        await controller.updateSynthesizerBar(false);
      }
    } finally {
      VisualizerFeed.instance.awaitingPermission = false;
    }
  }

  /// Explains what the access is for, then asks for it. True when granted.
  static Future<bool> request(BuildContext context) async {
    if (!needed) return true;
    if (await Permission.microphone.isGranted) return true;
    if (!context.mounted) return false;
    final feed = VisualizerFeed.instance;
    final wasAwaiting = feed.awaitingPermission;
    feed.awaitingPermission = true;
    try {
      final go = await showDialog<bool>(
        context: context,
        builder: (_) => const _ExplainDialog(),
      );
      if (context.mounted) {
        await context
            .read<AppController?>()
            ?.identity
            .setVisualizerAudioExplained(true);
      }
      if (go != true) return false;
      final status = await Permission.microphone.request();
      if (status.isPermanentlyDenied && context.mounted) {
        final open = await showDialog<bool>(
          context: context,
          builder: (_) => const _OpenSettingsDialog(),
        );
        if (open == true) await openAppSettings();
      }
      return status.isGranted;
    } finally {
      feed.awaitingPermission = wasAwaiting;
    }
  }
}

class _ExplainDialog extends StatelessWidget {
  const _ExplainDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Allow audio access?'),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The visualizer draws its bars from the music Pear Music is '
            'playing. Android files this under the microphone permission, so '
            'the next prompt will ask for microphone access.',
          ),
          SizedBox(height: 12),
          Text(
            'The microphone is never used. Nothing is recorded, saved or sent '
            'anywhere: the sound is analysed on your phone only to move the '
            'bars.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

class _OpenSettingsDialog extends StatelessWidget {
  const _OpenSettingsDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Audio access is blocked'),
      content: const Text(
        'To use the visualizer, allow the Microphone permission for Pear '
        'Music in the system settings. It is only used to read the music '
        'that is playing.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Open settings'),
        ),
      ],
    );
  }
}
