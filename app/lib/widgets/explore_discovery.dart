import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/artwork_service.dart';
import '../services/recommendation_service.dart';
import '../services/youtube_search_service.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';
import 'youtube_song_tile.dart';

/// Window width from which Explore lays out for a desktop: larger cards and
/// chart rows in two columns.
const double kExploreWideWidth = 900;

/// The Explore page: a kicker and title,
/// the search field, angular genre chips, then the page's own data as
/// sections with spaced-capitals headers. It only draws what the screen
/// hands it; loading, searching and the radio mix stay in the screen.
class ExploreDiscoveryView extends StatelessWidget {
  const ExploreDiscoveryView({
    super.key,
    required this.searchField,
    required this.genres,
    required this.selectedGenre,
    required this.liveOnly,
    required this.onGenreTap,
    required this.onLiveTap,
    required this.query,
    required this.isSearching,
    required this.error,
    required this.onRetry,
    required this.results,
    required this.recommended,
    required this.isLoadingRecommendations,
    required this.seedLabel,
    required this.onPlayMix,
    required this.onReroll,
    this.currentSongId,
  });

  final Widget searchField;
  final List<String> genres;
  final String? selectedGenre;
  final bool liveOnly;
  final ValueChanged<String> onGenreTap;
  final VoidCallback onLiveTap;

  /// The text in the search field, trimmed.
  final String query;
  final bool isSearching;
  final String? error;
  final VoidCallback onRetry;
  final List<YouTubeSearchResult> results;
  final List<YouTubeSearchResult> recommended;
  final bool isLoadingRecommendations;
  final String seedLabel;
  final VoidCallback? onPlayMix;
  final VoidCallback onReroll;
  final String? currentSongId;

  /// How many recommendations sit on the card shelf; the rest are the
  /// numbered chart below it.
  static const int shelfCount = 12;

  /// The least width of a shelf card in a wide window.
  static const double _wideCard = 160;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= kExploreWideWidth;
        final side = wide ? 28.0 : 16.0;
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  side,
                  pearShortScreen(context) ? 8 : (wide ? 28 : 16),
                  side,
                  0,
                ),
                child: _Header(wide: wide),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(side, 14, side, 12),
                child: searchField,
              ),
            ),
            SliverToBoxAdapter(child: _chips(side)),
            ..._body(context, wide, side, constraints.maxWidth),
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        );
      },
    );
  }

  Widget _chips(double side) {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: side),
        children: [
          ExploreChip(
            label: 'Live',
            icon: Icons.sensors_rounded,
            selected: liveOnly,
            onTap: onLiveTap,
          ),
          for (final genre in genres) ...[
            const SizedBox(width: 8),
            ExploreChip(
              label: genre,
              selected: selectedGenre == genre,
              onTap: () => onGenreTap(genre),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _body(
    BuildContext context,
    bool wide,
    double side,
    double width,
  ) {
    Widget boxed(Widget child) => SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(side, 20, side, 0),
            child: child,
          ),
        );

    if (isSearching) {
      return [
        boxed(const ExploreStatePanel(
          loading: true,
          title: 'Searching music',
        )),
      ];
    }
    if (error != null) {
      return [
        boxed(ExploreStatePanel(
          icon: Icons.error_outline_rounded,
          title: 'Search failed',
          message: error,
          actionLabel: 'Retry',
          onAction: onRetry,
          isError: true,
        )),
      ];
    }
    if (results.isNotEmpty) {
      return [
        boxed(ExploreSectionHeader('Results', count: results.length)),
        _rows(results, wide, numbered: false),
      ];
    }
    if (query.isNotEmpty) {
      return [
        boxed(ExploreStatePanel(
          icon: Icons.search_off_rounded,
          title: 'No songs found for "$query"',
          message: 'Try different keywords or check spelling.',
        )),
      ];
    }

    // Wide, the shelf is two whole rows of cards; the rest are the chart.
    final shelfSize = wide
        ? 2 * ExploreShelf.fitColumns(width - 2 * side, _wideCard)
        : shelfCount;
    final shelf = recommended.take(shelfSize).toList();
    final chart = recommended.skip(shelfSize).toList();
    return [
      boxed(_QuickMix(
        seedLabel: seedLabel,
        onPlay: recommended.isEmpty ? null : onPlayMix,
        onReroll: isLoadingRecommendations ? null : onReroll,
        loading: isLoadingRecommendations,
      )),
      if (isLoadingRecommendations && recommended.isEmpty)
        boxed(const ExploreStatePanel(
          loading: true,
          title: 'Finding music for you',
        ))
      else if (recommended.isEmpty)
        boxed(const ExploreStatePanel(
          icon: Icons.wifi_off_rounded,
          title: 'No recommendations found',
          message: 'Check your connection, or try searching above.',
        ))
      else ...[
        boxed(const ExploreSectionHeader('For you')),
        SliverToBoxAdapter(
          child: ExploreShelf(
            items: shelf,
            cardSize: wide ? _wideCard : 132,
            fit: wide,
            padding: side,
            currentSongId: currentSongId,
          ),
        ),
        if (chart.isNotEmpty) ...[
          boxed(ExploreSectionHeader('Up next', count: chart.length)),
          _rows(chart, wide, numbered: true, firstNumber: shelf.length + 1),
        ],
      ],
    ];
  }

  Widget _rows(
    List<YouTubeSearchResult> items,
    bool wide, {
    required bool numbered,
    int firstNumber = 1,
  }) {
    Widget row(int index) {
      final item = items[index];
      final tile = YouTubeSongTile(
        key: ValueKey('explore_${item.videoId}'),
        result: item,
        allResults: items,
        isCurrent: exploreIsCurrent(item, currentSongId),
        radioOnPlay: true,
      );
      if (!numbered) return tile;
      return Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(
              (firstNumber + index).toString().padLeft(2, '0'),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
                fontFeatures: [FontFeature.tabularFigures()],
                color: Colors.white54,
              ),
            ),
          ),
          Expanded(child: tile),
        ],
      );
    }

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(wide ? 16 : 0, 6, wide ? 16 : 0, 0),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: wide ? 2 : 1,
          mainAxisExtent: PearRow.extent,
          crossAxisSpacing: 12,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) => row(index),
      ),
    );
  }
}

/// Whether [item] is the song now playing, as a stream or a saved copy.
bool exploreIsCurrent(YouTubeSearchResult item, String? currentSongId) =>
    currentSongId == 'stream_${item.videoId}' ||
    (currentSongId != null &&
        RecommendationService.extractVideoId(currentSongId) == item.videoId);

TextStyle _caps(double size, Color color) => TextStyle(
      fontSize: size,
      fontWeight: FontWeight.w800,
      letterSpacing: 2.2,
      color: color,
    );

class _Header extends StatelessWidget {
  const _Header({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('EXPLORE', style: _caps(11, accent)),
        const SizedBox(height: 6),
        Text(
          'Find something new',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: (wide
                  ? theme.textTheme.headlineMedium
                  : pearShortScreen(context)
                  ? theme.textTheme.titleLarge
                  : theme.textTheme.headlineSmall)
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}

/// A genre or mood chip: square with one cut corner, filled with the
/// accent when selected.
class ExploreChip extends StatelessWidget {
  const ExploreChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final ink = selected
        ? (accent.computeLuminance() > 0.35
            ? const Color(0xFF15161A)
            : Colors.white)
        : Colors.white70;
    final shape = RoundedRectangleBorder(
      side: selected
          ? BorderSide.none
          : BorderSide(color: Colors.white.withValues(alpha: PearGlassTokens.edge)),
    );
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? accent
            : Colors.white.withValues(alpha: PearGlassTokens.cardFill),
        shape: shape,
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          customBorder: shape,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: ink),
                  const SizedBox(width: 6),
                ],
                Text(label.toUpperCase(), style: _caps(10.5, ink)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A section header in spaced capitals with an accent tick, a hairline and
/// an optional count.
class ExploreSectionHeader extends StatelessWidget {
  const ExploreSectionHeader(this.label, {super.key, this.count});

  final String label;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Container(width: 3, height: 12, color: accent),
        const SizedBox(width: 8),
        Text(label.toUpperCase(), style: _caps(11.5, Colors.white)),
        if (count != null) ...[
          const SizedBox(width: 10),
          PearCountChip('$count', color: accent),
        ],
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            height: 1,
            color: Colors.white.withValues(alpha: PearGlassTokens.edge),
          ),
        ),
      ],
    );
  }
}

class _QuickMix extends StatelessWidget {
  const _QuickMix({
    required this.seedLabel,
    required this.onPlay,
    required this.onReroll,
    required this.loading,
  });

  final String seedLabel;
  final VoidCallback? onPlay;
  final VoidCallback? onReroll;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return PearGlass(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('QUICK RADIO MIX', style: _caps(10.5, accent)),
                  const SizedBox(height: 6),
                  Text(
                    seedLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                tooltip: 'Re-roll recommendations',
                onPressed: onReroll,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: onPlay,
              style: FilledButton.styleFrom(
                shape: const RoundedRectangleBorder(
                ),
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: const Text('Play'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A shelf of square cards; tapping one starts a radio from it, like a
/// recommendation row. On a phone it scrolls sideways; with [fit] the cards
/// fill whole rows edge to edge instead.
class ExploreShelf extends StatelessWidget {
  const ExploreShelf({
    super.key,
    required this.items,
    required this.cardSize,
    required this.padding,
    this.currentSongId,
    this.fit = false,
  });

  final List<YouTubeSearchResult> items;

  /// The card's width when scrolling; with [fit], its least width.
  final double cardSize;
  final double padding;
  final String? currentSongId;
  final bool fit;

  static const double _gap = 12;

  /// How many cards of at least [minCard] fit across [width].
  static int fitColumns(double width, double minCard) =>
      math.max(1, ((width + _gap) / (minCard + _gap)).floor());

  @override
  Widget build(BuildContext context) {
    if (fit) {
      return LayoutBuilder(
        builder: (context, box) {
          final width = box.maxWidth - 2 * padding;
          final columns = fitColumns(width, cardSize);
          // A hair under, so rounding never pushes the last card to a new run.
          final size = (width - _gap * (columns - 1)) / columns - 0.01;
          return Padding(
            padding: EdgeInsets.fromLTRB(padding, 12, padding, 0),
            child: Wrap(
              spacing: _gap,
              runSpacing: 16,
              children: [
                for (final item in items)
                  ExploreCard(
                    result: item,
                    size: size,
                    isCurrent: exploreIsCurrent(item, currentSongId),
                  ),
              ],
            ),
          );
        },
      );
    }
    return SizedBox(
      // The top gap, the square, then two lines of text under it with room
      // for larger system text.
      height: cardSize + 12 + 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(padding, 12, padding, 0),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: _gap),
        itemBuilder: (context, index) => ExploreCard(
          result: items[index],
          size: cardSize,
          isCurrent: exploreIsCurrent(items[index], currentSongId),
        ),
      ),
    );
  }
}

class ExploreCard extends StatelessWidget {
  const ExploreCard({
    super.key,
    required this.result,
    required this.size,
    this.isCurrent = false,
  });

  final YouTubeSearchResult result;
  final double size;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final shape = RoundedRectangleBorder(
      side: BorderSide(
        color: isCurrent ? accent : PearGlassTokens.cardRim,
        width: isCurrent ? 2 : 1,
      ),
    );
    final thumb = result.thumbnailUrl;
    final placeholder = ColoredBox(
      color: PearGlassTokens.angularPanel,
      child: Icon(Icons.music_note, color: accent, size: size / 4),
    );
    return SizedBox(
      width: size,
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: () =>
            context.read<AppController>().player.startRadio(result.toSong()),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: size,
              height: size,
              clipBehavior: Clip.antiAlias,
              decoration: ShapeDecoration(shape: shape),
              foregroundDecoration: ShapeDecoration(shape: shape),
              child: thumb == null || thumb.isEmpty
                  ? placeholder
                  : Image.network(
                      ArtworkService.optimizeArtworkUrl(thumb),
                      fit: BoxFit.cover,
                      cacheWidth: (size * 2).round(),
                      gaplessPlayback: true,
                      loadingBuilder: (_, child, progress) =>
                          progress == null ? child : placeholder,
                      errorBuilder: (_, _, _) => placeholder,
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              result.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: isCurrent ? accent : null,
              ),
            ),
            Text(
              result.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Loading, empty and error read-outs: a Graphite panel with an icon or a
/// spinner, a line of text and an optional action.
class ExploreStatePanel extends StatelessWidget {
  const ExploreStatePanel({
    super.key,
    required this.title,
    this.icon,
    this.message,
    this.actionLabel,
    this.onAction,
    this.loading = false,
    this.isError = false,
  });

  final String title;
  final IconData? icon;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool loading;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tone = isError ? scheme.error : scheme.primary;
    return PearGlass(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        child: Column(
          children: [
            if (loading)
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              )
            else if (icon != null)
              Icon(icon, size: 36, color: tone),
            const SizedBox(height: 14),
            Text(
              title.toUpperCase(),
              textAlign: TextAlign.center,
              style: _caps(12, isError ? scheme.error : Colors.white),
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  shape: const RoundedRectangleBorder(
                  ),
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
