import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/screens/explore_screen.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_search_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/explore_discovery.dart';
import 'package:peerm_app/widgets/youtube_song_tile.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings > New design swaps Explore for the Graphite discovery page and
/// leaves the current page alone when off.
void main() {
  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return Directory.systemTemp.path;
    });
  });

  const phone = Size(430, 920);
  const wide = Size(1440, 900);

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = phone,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final history = HistoryService(prefs);
    final player = PlayerService(library, identity: identity, history: history);
    final controller = AppController(
      identity: identity,
      library: library,
      player: player,
      youtube: YoutubeService(),
      history: history,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(value: controller),
          ChangeNotifierProvider<PlayerService>.value(value: player),
          ChangeNotifierProvider<IdentityService>.value(value: identity),
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<HistoryService>.value(value: history),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  List<YouTubeSearchResult> songs(int n) => [
        for (var i = 0; i < n; i++)
          YouTubeSearchResult(
            videoId: 'vid$i',
            title: 'A rather long song title number $i that needs to be cut',
            author: 'Artist $i',
            duration: const Duration(minutes: 3, seconds: 20),
          ),
      ];

  Widget view({
    List<YouTubeSearchResult> results = const [],
    List<YouTubeSearchResult> recommended = const [],
    String query = '',
    bool isSearching = false,
    bool loadingRecs = false,
    String? error,
    VoidCallback? onRetry,
    ValueChanged<String>? onGenreTap,
  }) =>
      ExploreDiscoveryView(
        searchField: const TextField(),
        genres: const ['Trending', 'Chill & Lofi', 'Synthwave', 'Jazz'],
        selectedGenre: 'Trending',
        liveOnly: false,
        onGenreTap: onGenreTap ?? (_) {},
        onLiveTap: () {},
        query: query,
        isSearching: isSearching,
        error: error,
        onRetry: onRetry ?? () {},
        results: results,
        recommended: recommended,
        isLoadingRecommendations: loadingRecs,
        seedLabel: 'Based on "Song 1"',
        onPlayMix: () {},
        onReroll: () {},
      );

  for (final size in [phone, wide]) {
    final label = size == phone ? 'phone' : 'wide';

    testWidgets('on, $label: the discovery page with its empty read-out', (
      tester,
    ) async {
      await pump(tester, const ExploreScreen(isActive: false), size: size);
      expect(find.byType(ExploreDiscoveryView), findsOneWidget);
      expect(find.byType(SearchBar), findsNothing);
      expect(find.text('EXPLORE'), findsOneWidget);
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('TRENDING'), findsOneWidget);
      expect(find.text('QUICK RADIO MIX'), findsOneWidget);
      expect(find.text('NO RECOMMENDATIONS FOUND'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$label: shelf of cards, then a numbered chart', (
      tester,
    ) async {
      await pump(tester, view(recommended: songs(30)), size: size);
      expect(find.text('FOR YOU'), findsOneWidget);
      expect(find.byType(ExploreCard), findsWidgets);
      expect(find.text('UP NEXT'), findsOneWidget);
      final cards = find.byType(ExploreCard);
      // The phone shelf scrolls (only the visible cards are built).
      final shelf = size == phone
          ? ExploreDiscoveryView.shelfCount
          : cards.evaluate().length;
      // The chart carries on from the last card.
      expect(find.text('${shelf + 1}'.padLeft(2, '0')), findsOneWidget);
      final cardSize = tester.getSize(cards.first).width;
      if (size == phone) {
        expect(cardSize, 132);
      } else {
        // Two whole rows that start and end on the content edges (28 px in).
        expect(shelf % 2, 0);
        final perRow = shelf ~/ 2;
        expect(tester.getTopLeft(cards.first).dx, closeTo(28, 0.5));
        final lastInRow = tester.getTopRight(cards.at(perRow - 1)).dx;
        expect(lastInRow, closeTo(size.width - 28, 0.5));
        expect(
          tester.getTopLeft(cards.at(perRow)).dy,
          greaterThan(tester.getTopLeft(cards.first).dy),
        );
        expect(cardSize, greaterThanOrEqualTo(160));
      }

      final tiles = find.byType(YouTubeSongTile);
      final first = tester.getTopLeft(tiles.at(0));
      final second = tester.getTopLeft(tiles.at(1));
      if (size == phone) {
        expect(second.dy, greaterThan(first.dy), reason: 'one column');
      } else {
        expect(second.dy, first.dy, reason: 'two columns side by side');
      }

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a genre chip reports its tap', (tester) async {
    String? tapped;
    await pump(tester, view(onGenreTap: (g) => tapped = g));
    await tester.tap(find.text('CHILL & LOFI'));
    expect(tapped, 'Chill & Lofi');
  });

  testWidgets('search results show with their count', (tester) async {
    await pump(tester, view(results: songs(5), query: 'lofi'));
    expect(find.text('RESULTS'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('QUICK RADIO MIX'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading states', (tester) async {
    await pump(tester, view(isSearching: true, query: 'lofi'));
    expect(find.text('SEARCHING MUSIC'), findsOneWidget);
    await pump(tester, view(loadingRecs: true));
    expect(find.text('FINDING MUSIC FOR YOU'), findsOneWidget);
  });

  testWidgets('no results for a search', (tester) async {
    await pump(tester, view(query: 'zzzz'));
    expect(find.text('NO SONGS FOUND FOR "ZZZZ"'), findsOneWidget);
  });

  for (final size in [phone, wide]) {
    testWidgets('error state with Retry, ${size.width}', (tester) async {
      var retried = 0;
      await pump(
        tester,
        view(
          error: 'Search failed: SocketException: no route to host',
          query: 'lofi',
          onRetry: () => retried++,
        ),
        size: size,
      );
      expect(find.text('SEARCH FAILED'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      expect(retried, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
