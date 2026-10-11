import 'package:flutter/material.dart';

import '../models/song.dart';
import '../services/live_hls_proxy.dart';
import '../services/stream_cache_manager.dart';

/// Whether [song] is a live stream: listed as live, or found to be live this
/// session when it was fetched (a row that was not marked when it was listed).
bool isLiveSong(Song song) =>
    song.isLive ||
    (song.id.startsWith('stream_') &&
        StreamCacheManager.isKnownLive(song.id.substring(7)));

/// "Live stream" and how much data it has used so far (the relay counts what
/// crosses the network); just the plain words until the first bytes arrive.
class LiveLabel extends StatelessWidget {
  const LiveLabel({super.key, this.style, this.compact = false});

  final TextStyle? style;

  /// Only the amount ("1.8 MB") once there is one, for narrow places such as
  /// the mini player, where the full words were cut off.
  final bool compact;

  static String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).round()} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: LiveHlsProxy.bytesUsed,
      builder: (context, bytes, _) => Text(
        bytes <= 0
            ? 'Live stream'
            : (compact ? _size(bytes) : 'Live stream · ${_size(bytes)} used'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }
}

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
