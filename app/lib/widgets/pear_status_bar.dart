import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/player_service.dart';
import '../services/update_service.dart';

/// Thin classic status bar along the bottom of wide windows: library counts on
/// the left, current playback in the middle, app name on the right.
class PearStatusBar extends StatelessWidget {
  const PearStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();

    return Container(
      key: const ValueKey('pear_status_bar'),
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF131316),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          Text(
            '${controller.songs.length} songs · ${controller.playlists.length} playlists',
            style: const TextStyle(fontSize: 11.5, color: Colors.white54),
          ),
          const Spacer(),
          const _PlaybackStatus(),
          const SizedBox(width: 20),
          Text(
            'Pear Music v${UpdateService.displayVersion}',
            style: const TextStyle(fontSize: 11.5, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}

class _PlaybackStatus extends StatelessWidget {
  const _PlaybackStatus();

  String _formatTime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
    return '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final song = player.currentSong;
    final theme = Theme.of(context);

    if (song == null) {
      return const Text(
        'Stopped',
        style: TextStyle(fontSize: 11.5, color: Colors.white38),
      );
    }

    return StreamBuilder<Duration>(
      stream: player.positionStream,
      initialData: player.position ?? Duration.zero,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final duration = player.duration ?? Duration.zero;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              player.playing ? Icons.play_arrow_rounded : Icons.pause_rounded,
              size: 13,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                '${player.playing ? 'Playing' : 'Paused'}: ${song.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: Colors.white70),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${_formatTime(position)} / ${_formatTime(duration)}',
              style: const TextStyle(
                fontSize: 11.5,
                color: Colors.white54,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        );
      },
    );
  }
}
