import 'package:flutter/material.dart';

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
