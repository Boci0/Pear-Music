import 'dart:async';
import '../theme/glass.dart';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../services/debug_log.dart';
import '../services/player_service.dart';
import '../services/recommendation_service.dart';
import '../services/youtube_search_service.dart';
import '../widgets/explore_discovery.dart';

/// Middle section: Explore music with YouTube search, stream playback,
/// mood/genre pills, and dynamic recommended music feeds.
class ExploreScreen extends StatefulWidget {
  final bool isActive;
  const ExploreScreen({super.key, this.isActive = true});

  static final ValueNotifier<String> _searchRequests = ValueNotifier('');

  /// Searches online for [query] as typing it here does. Library's "Search
  /// online" row calls this, then switches to this tab.
  static void requestSearch(String query) {
    // Cleared first so asking for the same query twice still notifies.
    _searchRequests.value = '';
    _searchRequests.value = query;
  }

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<YouTubeSearchResult> _results = [];
  List<YouTubeSearchResult> _recommendedResults = [];
  bool _isLoading = false;
  bool _isLoadingRecommendations = false;
  String? _error;
  String _lastQuery = '';

  /// Whether the last search was the live-streams-only one.
  bool _lastSearchLive = false;

  /// The Live pill: search for streams that are on right now.
  bool _liveOnly = false;
  Timer? _debounceTimer;
  int _searchToken = 0;
  String? _selectedGenre;
  String _recommendationSeedLabel = 'Trending Mix';
  String? _lastRecommendationSeedTitle;

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
    ExploreScreen._searchRequests.addListener(_onSearchRequest);
    if (widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadRecommendations();
      });
    }
  }

  @override
  void didUpdateWidget(covariant ExploreScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      if (_recommendedResults.isEmpty && !_isLoadingRecommendations) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadRecommendations();
        });
      }
    }
  }

  @override
  void dispose() {
    ExploreScreen._searchRequests.removeListener(_onSearchRequest);
    _debounceTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadRecommendations() async {
    if (_isLoadingRecommendations) return;
    setState(() {
      _isLoadingRecommendations = true;
    });
    DebugLog.write('[explore] re-roll start');

    try {
      final controller = context.read<AppController>();
      final librarySongs = controller.songs;
      final random = Random();
      List<YouTubeSearchResult> items = [];
      String source = 'none';
      String seedLabel = 'Trending Mix';

      final candidateLibrary = librarySongs
          .where((s) => s.title != _lastRecommendationSeedTitle)
          .toList();
      // Always follow a library song when one is available. The search-based
      // fallback feeds return far fewer items (about 15) than a radio mix
      // (about 50), and that size jump on re-roll read as the list growing.
      final useLibrary = candidateLibrary.isNotEmpty;

      if (useLibrary) {
        final seed = candidateLibrary[random.nextInt(candidateLibrary.length)];
        seedLabel = 'Based on "${seed.title}"';
        _lastRecommendationSeedTitle = seed.title;

        try {
          final batch = await RecommendationService.fetchRadio(seed);
          if (batch.items.isNotEmpty) {
            source = 'radio';
            items = batch.items
                .map(
                  (item) => YouTubeSearchResult(
                    videoId: item.videoId,
                    title: item.title,
                    author: item.artist,
                    duration: item.duration,
                    thumbnailUrl: item.thumbnailUrl,
                  ),
                )
                .toList();
          }
        } catch (e) {
          DebugLog.write('[explore] recommendations failed: $e');
        }

        if (items.isEmpty) {
          try {
            final clean = RecommendationService.cleanSongQuery(seed);
            items = await YouTubeSearchService.search(
              '$clean songs',
              limit: 30,
            );
            if (items.isNotEmpty) source = 'radio-search';
          } catch (e) {
            DebugLog.write('[explore] radio search failed: $e');
          }
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
        items = await YouTubeSearchService.search(chosen, limit: 30);
        source = 'curated';
      }

      if (mounted) {
        final previousCount = _recommendedResults.length;
        setState(() {
          _recommendedResults = items;
          _recommendationSeedLabel = seedLabel;
          _isLoadingRecommendations = false;
        });
        DebugLog.write(
          '[explore] re-roll done: source=$source seed="$seedLabel" '
          'items=${items.length} previous=$previousCount',
        );
      }
    } catch (e) {
      DebugLog.write('[explore] re-roll failed: $e');
      if (mounted) {
        setState(() {
          _isLoadingRecommendations = false;
        });
      }
    }
  }

  void _onSearchRequest() {
    final query = ExploreScreen._searchRequests.value.trim();
    if (query.isEmpty || !mounted) return;
    _searchController.text = query;
    _performSearch(query);
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
    final live = _liveOnly;
    if (trimmed == _lastQuery &&
        live == _lastSearchLive &&
        _results.isNotEmpty) {
      return;
    }
    _lastQuery = trimmed;
    _lastSearchLive = live;
    final token = ++_searchToken;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // The first 20 show as soon as they land; later pages fill in after.
      final results = live
          ? await YouTubeSearchService.searchLive(trimmed)
          : await YouTubeSearchService.search(
              trimmed,
              limit: 60,
              // Streams that are on now are mixed in among the first results.
              includeLive: true,
              onFirstPage: (page) {
                if (!mounted || token != _searchToken) return;
                setState(() {
                  _results = page;
                  _isLoading = false;
                });
              },
            );
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

  void _toggleLive() {
    setState(() => _liveOnly = !_liveOnly);
    final typed = _searchController.text.trim();
    if (typed.isNotEmpty) {
      _performSearch(typed);
    } else if (_liveOnly) {
      _performSearch('live radio');
    } else {
      setState(() {
        _results = [];
        _lastQuery = '';
      });
    }
  }

  void _toggleGenre(String genre) {
    final selected = _selectedGenre != genre;
    setState(() {
      _selectedGenre = selected ? genre : null;
    });
    if (selected) {
      final term = _genreSearchQueries[genre] ?? genre;
      _searchController.text = term;
      _performSearch(term);
    } else {
      _searchController.clear();
      setState(() {
        _results = [];
        _lastQuery = '';
      });
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _results = [];
      _lastQuery = '';
      _selectedGenre = null;
    });
  }

  Future<void> _playQuickMix(PlayerService player) async {
    final queue = _recommendedResults.map((r) => r.toSong()).toList();
    await player.playSong(
      queue.first,
      queue: queue,
      sourceId: 'explore:quickmix',
      sourceTitle: 'Explore: $_recommendationSeedLabel',
    );
  }

  /// The Graphite discovery page.
  Widget _buildPage(PlayerService player, String? currentSongId) {
    final searchField = TextField(
      controller: _searchController,
      focusNode: _searchFocusNode,
      onChanged: (q) {
        _onQueryChanged(q);
        // The page switches between discovery and its empty read-out.
        setState(() {});
      },
      onSubmitted: _performSearch,
      decoration: InputDecoration(
        hintText: 'Search songs, artists, or paste link...',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchController,
          builder: (context, value, _) => value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.clear_rounded),
                  onPressed: _clearSearch,
                ),
        ),
        filled: true,
        fillColor: PearGlassTokens.angularPanel,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: PearGlassTokens.cardRim),
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: PearGlassTokens.cardRim),
        ),
      ),
    );
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ExploreDiscoveryView(
          searchField: searchField,
          genres: _genres,
          selectedGenre: _selectedGenre,
          liveOnly: _liveOnly,
          onGenreTap: _toggleGenre,
          onLiveTap: _toggleLive,
          query: _searchController.text.trim(),
          isSearching: _isLoading,
          error: _error,
          onRetry: () => _performSearch(_lastQuery),
          results: _results,
          recommended: _recommendedResults,
          isLoadingRecommendations: _isLoadingRecommendations,
          seedLabel: _recommendationSeedLabel,
          onPlayMix: () => _playQuickMix(player),
          onReroll: _loadRecommendations,
          currentSongId: currentSongId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerService>();
    final currentSongId = context.select<PlayerService, String?>(
      (p) => p.currentSong?.id,
    );

    return CallbackShortcuts(
      bindings: {
        // Ctrl+F focuses the Explore search box on desktop.
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            _searchFocusNode.requestFocus(),
      },
      child: _buildPage(player, currentSongId),
    );
  }
}
