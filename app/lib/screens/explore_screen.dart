import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/player_service.dart';
import '../services/recommendation_service.dart';
import '../services/youtube_search_service.dart';
import '../widgets/youtube_song_tile.dart';

/// Middle section: Explore music with YouTube search, stream playback,
/// mood/genre pills, and dynamic recommended music feeds.
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _genreScrollController = ScrollController();
  List<YouTubeSearchResult> _results = [];
  List<YouTubeSearchResult> _recommendedResults = [];
  bool _isLoading = false;
  bool _isLoadingRecommendations = false;
  String? _error;
  String _lastQuery = '';
  Timer? _debounceTimer;
  int _searchToken = 0;
  String? _selectedGenre;
  String _recommendationSeedLabel = 'Trending Mix';
  String? _lastRecommendationSeedTitle;
  double _genreDragDistance = 0.0;

  static const List<String> _genres = [
    'Trending',
    'Chill & Lofi',
    'Synthwave',
    'Indie & Rock',
    'Electronic',
    'Acoustic',
    'Gaming',
    'Jazz',
    'Pop',
    'Hip Hop',
  ];

  static const Map<String, String> _genreSearchQueries = {
    'Trending': 'Trending Music Songs',
    'Chill & Lofi': 'Lofi Chill Beats',
    'Synthwave': 'Synthwave Retro Music',
    'Indie & Rock': 'Indie Rock Hits',
    'Electronic': 'Electronic Dance Hits',
    'Acoustic': 'Acoustic Guitar Hits',
    'Gaming': 'Gaming OST Music',
    'Jazz': 'Jazz Classics',
    'Pop': 'Popular Pop Songs',
    'Hip Hop': 'Hip Hop Hits',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadRecommendations();
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    _genreScrollController.dispose();
    super.dispose();
  }

  void _scrollGenreBy(double offset) {
    if (!_genreScrollController.hasClients) return;
    final target = (_genreScrollController.offset + offset).clamp(
      0.0,
      _genreScrollController.position.maxScrollExtent,
    );
    _genreScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _loadRecommendations({bool shuffle = false}) async {
    if (_isLoadingRecommendations) return;
    setState(() {
      _isLoadingRecommendations = true;
    });

    try {
      final controller = context.read<AppController>();
      final librarySongs = controller.songs;
      final random = Random();
      List<YouTubeSearchResult> items = [];
      String seedLabel = 'Trending Mix';

      final candidateLibrary = librarySongs
          .where((s) => s.title != _lastRecommendationSeedTitle)
          .toList();
      final useLibrary = candidateLibrary.isNotEmpty &&
          (random.nextBool() || (shuffle && librarySongs.length > 1));

      if (useLibrary) {
        final seed = candidateLibrary[random.nextInt(candidateLibrary.length)];
        seedLabel = 'Based on "${seed.title}"';
        _lastRecommendationSeedTitle = seed.title;

        try {
          final batch = await RecommendationService.fetchRadio(seed);
          if (batch.items.isNotEmpty) {
            items = batch.items
                .map((item) => YouTubeSearchResult(
                      videoId: item.videoId,
                      title: item.title,
                      author: item.artist,
                      duration: item.duration,
                      thumbnailUrl: item.thumbnailUrl,
                    ))
                .toList();
          }
        } catch (_) {}

        if (items.isEmpty) {
          final clean = RecommendationService.cleanSongQuery(seed);
          items = await YouTubeSearchService.search('$clean songs', limit: 15);
        }
      }

      if (items.isEmpty) {
        const curatedSeeds = [
          'Top Hits 2026',
          'Trending Music',
          'Chill Lo-Fi Beats',
          'Synthwave Chill',
          'Indie Pop Hits',
          'Acoustic Chill',
          'Electronic Dance',
          'Midnight Jazz',
        ];
        final remaining = curatedSeeds
            .where((s) => s != _lastRecommendationSeedTitle)
            .toList();
        final pool = remaining.isNotEmpty ? remaining : curatedSeeds;
        final chosen = pool[random.nextInt(pool.length)];
        seedLabel = chosen;
        _lastRecommendationSeedTitle = chosen;
        items = await YouTubeSearchService.search(chosen, limit: 15);
      }

      if (mounted) {
        setState(() {
          _recommendedResults = items;
          _recommendationSeedLabel = seedLabel;
          _isLoadingRecommendations = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoadingRecommendations = false;
        });
      }
    }
  }

  void _onQueryChanged(String query) {
    _debounceTimer?.cancel();
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _results = [];
        _lastQuery = '';
        _isLoading = false;
        _error = null;
        _selectedGenre = null;
      });
      return;
    }
    if (trimmed.length < 2) return;

    _debounceTimer = Timer(const Duration(milliseconds: 400), () {
      _performSearch(trimmed);
    });
  }

  Future<void> _performSearch(String query) async {
    _debounceTimer?.cancel();
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    if (trimmed == _lastQuery && _results.isNotEmpty) return;
    _lastQuery = trimmed;
    final token = ++_searchToken;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final results = await YouTubeSearchService.search(trimmed, limit: 25);
      if (mounted && token == _searchToken) {
        setState(() {
          _results = results;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted && token == _searchToken) {
        setState(() {
          _error = 'Search failed: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final player = context.watch<PlayerService>();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/pear_logo.png',
              width: 28,
              height: 28,
              filterQuality: FilterQuality.medium,
            ),
            const SizedBox(width: 8),
            const Text('Explore'),
          ],
        ),
        actions: [
          if (_searchController.text.isEmpty)
            IconButton(
              icon: const Icon(Icons.shuffle_rounded),
              tooltip: 'Shuffle recommendations',
              onPressed: _isLoadingRecommendations
                  ? null
                  : () => _loadRecommendations(shuffle: true),
            ),
        ],
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SearchBar(
              controller: _searchController,
              hintText: 'Search songs, artists, or paste link...',
              leading: const Icon(Icons.search_rounded),
              trailing: [
                if (_searchController.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear_rounded),
                    onPressed: () {
                      _searchController.clear();
                      setState(() {
                        _results = [];
                        _lastQuery = '';
                        _selectedGenre = null;
                      });
                    },
                  ),
              ],
              onChanged: _onQueryChanged,
              onSubmitted: _performSearch,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  tooltip: 'Scroll left',
                  icon: const Icon(Icons.chevron_left_rounded),
                  onPressed: () => _scrollGenreBy(-200),
                ),
                Expanded(
                  child: SizedBox(
                    height: 38,
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (_) {
                        _genreDragDistance = 0.0;
                      },
                      onPointerMove: (event) {
                        if (event.buttons == kPrimaryMouseButton &&
                            _genreScrollController.hasClients) {
                          _genreDragDistance += event.delta.dx.abs();
                          final newOffset =
                              (_genreScrollController.offset - event.delta.dx)
                                  .clamp(
                            0.0,
                            _genreScrollController.position.maxScrollExtent,
                          );
                          _genreScrollController.jumpTo(newOffset);
                        }
                      },
                      onPointerSignal: (pointerSignal) {
                        if (pointerSignal is PointerScrollEvent) {
                          final delta = pointerSignal.scrollDelta.dy != 0
                              ? pointerSignal.scrollDelta.dy
                              : pointerSignal.scrollDelta.dx;
                          if (delta != 0 && _genreScrollController.hasClients) {
                            final newOffset =
                                (_genreScrollController.offset + delta).clamp(
                              0.0,
                              _genreScrollController.position.maxScrollExtent,
                            );
                            _genreScrollController.jumpTo(newOffset);
                          }
                        }
                      },
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(context).copyWith(
                          dragDevices: {
                            PointerDeviceKind.touch,
                            PointerDeviceKind.mouse,
                            PointerDeviceKind.trackpad,
                            PointerDeviceKind.stylus,
                          },
                        ),
                        child: ListView.separated(
                          controller: _genreScrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          itemCount: _genres.length,
                          separatorBuilder: (_, index) =>
                              const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final genre = _genres[index];
                            final isSelected = _selectedGenre == genre;
                            return ChoiceChip(
                              label: Text(genre),
                              selected: isSelected,
                              onSelected: (selected) {
                                if (_genreDragDistance > 8.0) return;
                                setState(() {
                                  _selectedGenre = selected ? genre : null;
                                });
                                if (selected) {
                                  final term =
                                      _genreSearchQueries[genre] ?? genre;
                                  _searchController.text = term;
                                  _performSearch(term);
                                } else {
                                  _searchController.clear();
                                  setState(() {
                                    _results = [];
                                    _lastQuery = '';
                                  });
                                }
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  tooltip: 'Scroll right',
                  icon: const Icon(Icons.chevron_right_rounded),
                  onPressed: () => _scrollGenreBy(200),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (_isLoading)
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Searching music...'),
                  ],
                ),
              ),
            )
          else if (_error != null)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 48, color: scheme.error),
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.error),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.tonal(
                        onPressed: () => _performSearch(_lastQuery),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (_results.isNotEmpty)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 16, 6),
                    child: Row(
                      children: [
                        Text(
                          'Search Results',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${_results.length}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final item = _results[index];
                        final isCurrent =
                            player.currentSong?.id == 'stream_${item.videoId}';
                        return YouTubeSongTile(
                          result: item,
                          allResults: _results,
                          isCurrent: isCurrent,
                        );
                      },
                    ),
                  ),
                ],
              ),
            )
          else if (_searchController.text.trim().isNotEmpty)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search_off_rounded,
                          size: 48, color: scheme.onSurfaceVariant),
                      const SizedBox(height: 12),
                      Text(
                        'No songs found for "${_searchController.text.trim()}"',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Try different keywords or check spelling.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                children: [
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          scheme.primary.withValues(alpha: 0.18),
                          scheme.surfaceContainerHigh,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.25),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.radio_rounded,
                            size: 28,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Quick Radio Mix',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _recommendationSeedLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                          ),
                          icon: const Icon(Icons.play_arrow_rounded, size: 20),
                          label: const Text('Play'),
                          onPressed: _recommendedResults.isEmpty
                              ? null
                              : () async {
                                  final queue = _recommendedResults
                                      .map((r) => r.toSong())
                                      .toList();
                                  await player.playSong(
                                    queue.first,
                                    queue: queue,
                                    sourceId: 'explore:quickmix',
                                    sourceTitle:
                                        'Explore: $_recommendationSeedLabel',
                                  );
                                },
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Recommended For You',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (_isLoadingRecommendations)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                        tooltip: 'Re-roll recommendations',
                        onPressed: _isLoadingRecommendations
                            ? null
                            : () => _loadRecommendations(shuffle: true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (_isLoadingRecommendations &&
                      _recommendedResults.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else if (_recommendedResults.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'No recommendations found. Try searching above!',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  else
                    ..._recommendedResults.map((item) {
                      final isCurrent =
                          player.currentSong?.id == 'stream_${item.videoId}';
                      return YouTubeSongTile(
                        result: item,
                        allResults: _recommendedResults,
                        isCurrent: isCurrent,
                      );
                    }),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
