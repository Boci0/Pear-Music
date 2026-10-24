import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';
import '../widgets/pear_app_bar.dart';
import '../widgets/pear_page_route.dart';
import '../widgets/song_tile.dart';
import '../widgets/tactile_button.dart';

/// Home tab: where you left off, shortcuts to your own
/// music and what you played last. The other tabs stay where they are;
/// [onOpenTab] switches to one by its screen index, as the nav bar does.
///
/// shortcut: no "For you" mixes, Downloads or Offline tiles yet, there is no
/// data or screen behind them; add them when those exist.
class HomeFeedScreen extends StatelessWidget {
  const HomeFeedScreen({super.key, required this.onOpenTab});

  final ValueChanged<int> onOpenTab;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final history = controller.historySongs;
    final currentId = controller.player.currentSong?.id;

    final sideways = MediaQuery.sizeOf(context).height < 500;

    // The dock already shows a loaded song, so this only fills in before
    // anything is loaded.
    final Widget? continueCard = currentId == null && history.isNotEmpty
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Header('Continue listening'),
              Padding(
                padding: _gutter,
                child: PearGlass(
                  hero: true,
                  child: SongTile(
                    song: history.first,
                    queue: history,
                    sourceId: 'history',
                    sourceTitle: 'History',
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          )
        : null;
    // Sideways the tiles stack in a narrow column of one-line rows, so the
    // recent plays get the width.
    final tiles = [
      _Shortcut(
        key: const ValueKey('home_liked'),
        icon: Icons.favorite_rounded,
        label: 'Liked',
        count: controller.favoriteSongs.length,
        row: sideways,
        onTap: () => Navigator.of(
          context,
        ).push(PearPageRoute(builder: (_) => const LikedPage())),
      ),
      _Shortcut(
        key: const ValueKey('home_playlists'),
        icon: Icons.queue_music_rounded,
        label: 'Playlists',
        count: controller.playlists.length,
        row: sideways,
        onTap: () => onOpenTab(1),
      ),
      _Shortcut(
        key: const ValueKey('home_history'),
        icon: Icons.history_rounded,
        label: 'History',
        count: history.length,
        row: sideways,
        onTap: () => onOpenTab(3),
      ),
    ];
    final shortcuts = Padding(
      padding: _gutter,
      child: sideways
          ? Column(
              children: [
                for (final t in tiles) ...[t, const SizedBox(height: 8)],
              ],
            )
          : Row(
              children: [
                for (var k = 0; k < tiles.length; k++) ...[
                  if (k > 0) const SizedBox(width: 8),
                  Expanded(child: tiles[k]),
                ],
              ],
            ),
    );
    final recent = <Widget>[
      _Header(
        'Recently played',
        action: history.isEmpty
            ? null
            : TextButton(
                onPressed: () => onOpenTab(3),
                child: const Text('SEE ALL'),
              ),
      ),
      if (history.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          child: Text(
            'Songs you play show up here.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
          ),
        )
      else
        for (final song in history.take(6))
          SongTile(
            key: ValueKey('recent_${song.id}'),
            song: song,
            queue: history,
            sourceId: 'history',
            sourceTitle: 'History',
            isCurrent: song.id == currentId,
          ),
    ];

    return Scaffold(
      appBar: PearAppBar(
        label: 'Home',
        actions: [
          TactileIconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: 'Search',
            onPressed: () => onOpenTab(2),
          ),
          TactileIconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => onOpenTab(4),
          ),
        ],
      ),
      body: sideways
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 200,
                  child: ListView(
                    padding: const EdgeInsets.only(top: 4, bottom: 12),
                    children: [shortcuts],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(top: 4, bottom: 12),
                    children: [?continueCard, ...recent],
                  ),
                ),
              ],
            )
          : ListView(
              // Song rows bring their own side padding, like the History list.
              padding: const EdgeInsets.only(top: 8, bottom: 140),
              children: [
                ?continueCard,
                shortcuts,
                const SizedBox(height: 20),
                ...recent,
              ],
            ),
    );
  }
}

const EdgeInsets _gutter = EdgeInsets.symmetric(horizontal: 16);

/// Section title in spaced capitals, with an optional action on the right.
class _Header extends StatelessWidget {
  const _Header(this.text, {this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
    height: 36,
    padding: _gutter,
    child: Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.4,
              color: Colors.white.withValues(alpha: 0.38),
            ),
          ),
        ),
        ?action,
      ],
    ),
  );
}

/// An angular tile with an icon, a label and how many songs or lists it holds.
class _Shortcut extends StatelessWidget {
  const _Shortcut({
    super.key,
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
    this.row = false,
  });

  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;

  /// One line (icon, label, count) for the narrow sideways column.
  final bool row;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final labelText = Text(
      label.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
    final countText = Text(
      '$count',
      style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.5)),
    );
    return Material(
      color: PearGlassTokens.angularPanel,
      shape: PearGlassTokens.angularShape(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: () {
          TactileFeedback.selection();
          onTap();
        },
        child: row
            ? SizedBox(
                height: 48,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Icon(icon, size: 18, color: accent),
                      const SizedBox(width: 12),
                      Expanded(child: labelText),
                      countText,
                    ],
                  ),
                ),
              )
            : Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 20, color: accent),
                    const SizedBox(height: 10),
                    labelText,
                    const SizedBox(height: 2),
                    countText,
                  ],
                ),
              ),
      ),
    );
  }
}

/// Every liked song in one list, opened from the Liked tile and from
/// Library's Liked songs row.
class LikedPage extends StatelessWidget {
  const LikedPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final List<Song> songs = controller.favoriteSongs;
    final currentId = controller.player.currentSong?.id;
    return Scaffold(
      appBar: const PearAppBar(label: 'Liked', showBackButton: true),
      body: songs.isEmpty
          ? Center(
              child: Text(
                'Tap the heart on any song to keep it here.',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 140),
              itemExtent: PearRow.extent,
              itemCount: songs.length,
              itemBuilder: (context, i) => SongTile(
                song: songs[i],
                queue: songs,
                sourceId: 'favorites',
                sourceTitle: 'Favorites',
                isCurrent: songs[i].id == currentId,
              ),
            ),
    );
  }
}
