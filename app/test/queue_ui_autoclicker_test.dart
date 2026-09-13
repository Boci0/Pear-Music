import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/recommendation_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/player/queue_bottom_sheet.dart';
import 'package:peerm_app/widgets/song_tile.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(String id, String title, {String? sourceDeviceId}) => Song(
      id: id,
      title: title,
      fileName: '$id.mp3',
      size: 1024,
      checksum: 'chk_$id',
      sourceDeviceId: sourceDeviceId,
      addedAt: DateTime(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return Directory.systemTemp.path;
    });
  });

  Future<({AppController controller, LibraryService library, PlayerService player})> createEnvironment() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final player = PlayerService(library);
    final controller = AppController(
      identity: identity,
      library: library,
      player: player,
      youtube: YoutubeService(),
    );
    return (controller: controller, library: library, player: player);
  }

  Widget buildHarness({
    required AppController controller,
    required PlayerService player,
    required Widget child,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        ChangeNotifierProvider<PlayerService>.value(value: player),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: child,
        ),
      ),
    );
  }

  void configureViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  group('Automated UI Clicker Tests', () {
    testWidgets('Test Case 1: Tapping Start Radio on local track initializes radio and populates queue without token collision', (tester) async {
      configureViewport(tester);
      final env = await createEnvironment();
      const seedVideoId = 'dQw4w9WgXcQ';
      final songLocal = _song('local_1 [$seedVideoId]', 'Local Track 1');
      env.library.setSongsForTesting([songLocal]);

      // Seed mock radio recommendations
      final mockBatch = RecommendationBatch(
        items: [
          for (var i = 1; i <= 6; i++)
            RecommendationItem(
              videoId: 'recSong0000$i',
              title: 'Recommended Song $i',
              artist: 'Artist $i',
              duration: const Duration(minutes: 3),
            ),
        ],
      );
      RecommendationService.setRadioBatchForTesting(seedVideoId, mockBatch);

      await tester.pumpWidget(
        buildHarness(
          controller: env.controller,
          player: env.player,
          child: SongTile(song: songLocal),
        ),
      );
      await tester.pumpAndSettle();

      // Find and click the 'more_vert' menu button on the song tile
      final moreButton = find.byIcon(Icons.more_vert);
      expect(moreButton, findsOneWidget);
      await tester.tap(moreButton);
      await tester.pumpAndSettle();

      // Find and click 'Start Radio'
      final startRadioTile = find.text('Start Radio');
      expect(startRadioTile, findsOneWidget);
      await tester.tap(startRadioTile);
      await tester.pumpAndSettle();

      // Verify radio mode was started with session token intact
      expect(env.player.queueSourceId, 'radio');
      expect(env.player.currentSong?.id, songLocal.id);
      expect(env.player.queue.isNotEmpty, isTrue);

      // Wait for background recommendation fetch from startRadio to resolve into queue
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (env.player.queue.length > 1) break;
      }
      expect(env.player.queue.length, greaterThan(1));
      expect(env.player.queueIndex, 0);
    });

    testWidgets('Test Case 2: Tapping Play Next once on an earlier queue song places it strictly at N+1 and locks it', (tester) async {
      configureViewport(tester);
      final env = await createEnvironment();
      final songA = _song('a', 'Song A');
      final songB = _song('b', 'Song B');
      final songC = _song('c', 'Song C');
      final songD = _song('d', 'Song D');

      // Initial queue: [A, B, C, D], currently playing B (index 1)
      env.player.updateQueue([songA, songB, songC, songD]);
      env.player.currentSong = songB;
      expect(env.player.queueIndex, 1);

      // Render SongTile for songA (which sits before B)
      await tester.pumpWidget(
        buildHarness(
          controller: env.controller,
          player: env.player,
          child: SongTile(song: songA),
        ),
      );
      await tester.pumpAndSettle();

      // Click more options
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      // Click 'Play next' once
      final playNextOption = find.text('Play next');
      expect(playNextOption, findsOneWidget);
      await tester.tap(playNextOption);
      await tester.pumpAndSettle();

      // Verify songA moved to index N+1 (immediately after B, which is now at 0)
      expect(env.player.queue.length, 4);
      expect(env.player.queue[0].id, 'b');
      expect(env.player.queue[1].id, 'a');
      expect(env.player.queue[2].id, 'c');
      expect(env.player.queue[3].id, 'd');
      expect(env.player.queueIndex, 0);
      expect(env.player.isSongLocked('a'), isTrue);
    });

    testWidgets('Test Case 3: Tapping Play Next once on a later queue song moves it directly to N+1 and locks it', (tester) async {
      configureViewport(tester);
      final env = await createEnvironment();
      final songA = _song('a', 'Song A');
      final songB = _song('b', 'Song B');
      final songC = _song('c', 'Song C');
      final songD = _song('d', 'Song D');

      // Initial queue: [A, B, C, D], currently playing A (index 0)
      env.player.updateQueue([songA, songB, songC, songD]);
      env.player.currentSong = songA;
      expect(env.player.queueIndex, 0);

      // Render SongTile for songD (at the end of the queue)
      await tester.pumpWidget(
        buildHarness(
          controller: env.controller,
          player: env.player,
          child: SongTile(song: songD),
        ),
      );
      await tester.pumpAndSettle();

      // Click more options
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      // Click 'Play next' once
      final playNextOption = find.text('Play next');
      expect(playNextOption, findsOneWidget);
      await tester.tap(playNextOption);
      await tester.pumpAndSettle();

      // Verify songD is at index 1 (N+1)
      expect(env.player.queue.length, 4);
      expect(env.player.queue[0].id, 'a');
      expect(env.player.queue[1].id, 'd');
      expect(env.player.queue[2].id, 'b');
      expect(env.player.queue[3].id, 'c');
      expect(env.player.queueIndex, 0);
      expect(env.player.isSongLocked('d'), isTrue);
    });

    testWidgets('Test Case 4: Manually queued song is locked and retained against auto-rerolls', (tester) async {
      configureViewport(tester);
      final env = await createEnvironment();
      const seedVideoId = 'dQw4w9WgXcQ';
      final songA = _song('a [$seedVideoId]', 'Song A');
      final songB = _song('b', 'Song B');
      final songC = _song('c', 'Song C');

      RecommendationService.setRadioBatchForTesting(
        seedVideoId,
        RecommendationBatch(
          items: [
            for (var i = 1; i <= 6; i++)
              RecommendationItem(
                videoId: 'recReroll00$i',
                title: 'Reroll Song $i',
                artist: 'Artist $i',
                duration: const Duration(minutes: 3),
              ),
          ],
        ),
      );

      env.player.updateQueue([songA, songB]);
      env.player.currentSong = songA;
      expect(env.player.queueIndex, 0);

      // Add songC via SongTile context menu -> 'Add to queue'
      await tester.pumpWidget(
        buildHarness(
          controller: env.controller,
          player: env.player,
          child: SongTile(song: songC),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      final addToQueueOption = find.text('Add to queue');
      expect(addToQueueOption, findsOneWidget);
      await tester.tap(addToQueueOption);
      await tester.pumpAndSettle();

      // Verify songC is in queue and locked
      expect(env.player.queue.any((s) => s.id == 'c'), isTrue);
      expect(env.player.isSongLocked('c'), isTrue);

      // Trigger auto-reroll check
      await env.player.rerollNextTrackOnly();
      await tester.pumpAndSettle();

      // songC must still remain in queue
      expect(env.player.queue.any((s) => s.id == 'c'), isTrue);
    });

    testWidgets('Test Case 5: Tapping duplicate song instance in queue bottom sheet selects exact index without snapping back', (tester) async {
      configureViewport(tester);
      final env = await createEnvironment();
      final songA = _song('a', 'Song A');
      final songB = _song('b', 'Song B');
      final songC = _song('c', 'Song C');

      // Queue with duplicate: [A, B, C, A, B]
      // Indices: 0: A, 1: B, 2: C, 3: A (duplicate), 4: B
      final queueWithDuplicates = [songA, songB, songC, songA, songB];
      env.player.updateQueue(queueWithDuplicates);
      env.player.currentSong = songA;
      expect(env.player.queueIndex, 0);

      final sheetController = QueueSheetController();

      await tester.pumpWidget(
        buildHarness(
          controller: env.controller,
          player: env.player,
          child: ExpandableQueueSheet(
            player: env.player,
            controller: env.controller,
            accent: const Color(0xFF101014),
            minChildSize: 0.08,
            sheetController: sheetController,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Expand the queue sheet so list items are visible
      sheetController.expand();
      await tester.pumpAndSettle();

      // Target the duplicate instance of Song A at index 3
      final duplicateRowFinder = find.byKey(const ValueKey('queue_row_a_3'));
      expect(duplicateRowFinder, findsOneWidget);

      // Click the duplicate song row
      await tester.tap(duplicateRowFinder);
      await tester.pumpAndSettle();

      // Verify playback switched specifically to index 3, NOT resetting to index 0
      expect(env.player.queueIndex, 3);
      expect(env.player.currentSong?.id, 'a');
    });
  });
}
