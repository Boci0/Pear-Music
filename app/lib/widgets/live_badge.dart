import 'package:flutter/material.dart';

import '../models/song.dart';
import '../services/stream_cache_manager.dart';

/// Whether [song] is a live stream: listed as live, or found to be live this
/// session when it was fetched (a row that was not marked when it was listed).
bool isLiveSong(Song song) =>
    song.isLive ||
    (song.id.startsWith('stream_') &&
        StreamCacheManager.isKnownLive(song.id.substring(7)));

/// Small solid "LIVE" tag for live streams: search rows show it in place of
/// a length, the player shows it in place of the seek bar.
class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: scheme.error,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'LIVE',
        style: TextStyle(
          color: scheme.onError,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          height: 1.2,
        ),
      ),
    );
  }
}
