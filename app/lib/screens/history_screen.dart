import '../widgets/pear_sheet.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';
import '../widgets/pear_empty_state.dart';
import '../widgets/song_tile.dart';
import '../widgets/tactile_button.dart';
import 'home_shell.dart';

/// Short "when was this played" label for the History meta line: "just now",
/// "12 min ago", "3 h ago", "yesterday", "4 days ago", then a short date.
@visibleForTesting
String? playedAgo(DateTime? time, DateTime now) {
  if (time == null) return null;
  final diff = now.difference(time);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  // Past a day, count calendar days: a song played late on Monday was not
  // played "yesterday" early on Wednesday, however few hours ago that was.
  final local = time.toLocal();
  final today = now.toLocal();
  final days = (DateTime(today.year, today.month, today.day)
              .difference(DateTime(local.year, local.month, local.day))
              .inHours /
          24)
      .round();
  if (days <= 1) return 'yesterday';
  if (days < 7) return '$days days ago';
  return _shortDate(local, now);
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "21 Sep", with the year only when it is not this year.
String _shortDate(DateTime local, DateTime now) {
  final date = '${local.day} ${_months[local.month - 1]}';
  return local.year == now.year ? date : '$date ${local.year}';
}

/// Date header over a group of plays: TODAY, YESTERDAY,
/// then the date, by calendar day.
@visibleForTesting
String historyDayLabel(DateTime time, DateTime now) {
  final local = time.toLocal();
  final days = (DateUtils.dateOnly(now.toLocal())
              .difference(DateUtils.dateOnly(local))
              .inHours /
          24)
      .round();
  if (days <= 0) return 'TODAY';
  if (days == 1) return 'YESTERDAY';
  return _shortDate(local, now).toUpperCase();
}

/// History tab: every song that started playing, newest first, local files and
/// online streams mixed together in one list.
///
/// The list is intentionally plain (no filters, no grouping) and reuses
/// [SongTile], so rows cost the same as the library ones.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  Future<void> _confirmClear(
    BuildContext context,
    AppController controller,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => PearAlertDialog(
        title: const Text('Clear listening history?'),
        content: const Text(
          'This only clears the history list. Your songs, favorites and '
          'playlists are untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) {
      TactileFeedback.selection();
      await controller.clearHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final songs = controller.historySongs;
    final currentSongId = controller.player.currentSong?.id;
    // Song id -> last play time, so each row can say when it was played.
    final playedAt = <String, DateTime>{
      for (final entry in controller.history?.entries ?? const [])
        entry.songId: entry.playedAt,
    };
    final now = DateTime.now();

    return _GroupedHistory(
      songs: songs,
      playedAt: playedAt,
      currentSongId: currentSongId,
      now: now,
      onClear: () => _confirmClear(context, controller),
    );
  }
}

/// History: a kicker and title over plays grouped by day,
/// each row showing the time it was played.
class _GroupedHistory extends StatelessWidget {
  final List<Song> songs;
  final Map<String, DateTime> playedAt;
  final String? currentSongId;
  final DateTime now;
  final VoidCallback onClear;

  const _GroupedHistory({
    required this.songs,
    required this.playedAt,
    required this.currentSongId,
    required this.now,
    required this.onClear,
  });

  static TextStyle _spaced(Color color) => TextStyle(
        fontSize: 10,
        letterSpacing: 2.4,
        fontWeight: FontWeight.w600,
        color: color,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);

    // Day headers (String) and songs (Song) in reading order.
    final items = <Object>[];
    String? lastDay;
    for (final song in songs) {
      final time = playedAt[song.id];
      final day = time == null ? 'EARLIER' : historyDayLabel(time, now);
      if (day != lastDay) items.add(day);
      lastDay = day;
      items.add(song);
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final inset = constraints.maxWidth >= 900 ? 24.0 : 8.0;
            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    inset + 14,
                    pearShortScreen(context) ? 8 : 20,
                    inset,
                    8,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'HISTORY',
                                style: _spaced(theme.colorScheme.primary),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Recently played',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: (pearShortScreen(context)
                                        ? theme.textTheme.titleLarge
                                        : theme.textTheme.headlineSmall)
                                    ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (songs.isNotEmpty)
                          TactileIconButton(
                            icon: const Icon(Icons.delete_sweep_outlined),
                            tooltip: 'Clear history',
                            onPressed: onClear,
                          ),
                      ],
                    ),
                  ),
                ),
                if (songs.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: PearEmptyState(
                      icon: Icons.history_rounded,
                      title: 'Nothing played yet',
                      message: 'Songs you play show up here, newest first.',
                      actionLabel: 'Go to Library',
                      onAction: () => HomeShell.requestTab(0),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(inset, 0, inset, 140),
                    sliver: SliverList.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final item = items[i];
                        if (item is String) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                            child: Text(
                              item,
                              style: _spaced(
                                Colors.white.withValues(alpha: 0.55),
                              ),
                            ),
                          );
                        }
                        final song = item as Song;
                        final time = playedAt[song.id];
                        return SizedBox(
                          key: ValueKey(song.id),
                          height: PearRow.extent,
                          child: SongTile(
                            song: song,
                            queue: songs,
                            sourceId: 'history',
                            sourceTitle: 'History',
                            isCurrent: currentSongId == song.id,
                            metaSuffix: time == null
                                ? null
                                : localizations.formatTimeOfDay(
                                    TimeOfDay.fromDateTime(time.toLocal()),
                                    alwaysUse24HourFormat: use24h,
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
