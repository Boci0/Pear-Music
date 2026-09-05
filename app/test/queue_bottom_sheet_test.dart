import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/player/queue_bottom_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(String id, String title) => Song(
      id: id,
      title: title,
      fileName: '$id.mp3',
      size: 100,
      checksum: 'chk_$id',
      addedAt: DateTime(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ExpandableQueueSheet renders within 0.50 max height constraint', (
    tester,
  ) async {
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

    player.updateQueue(
      [for (var i = 1; i <= 5; i++) _song('s$i', 'Song $i')],
      sourceId: 'test',
      sourceTitle: 'Test',
    );

    final sheetController = QueueSheetController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(child: Placeholder()),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ExpandableQueueSheet(
                  player: player,
                  controller: controller,
                  accent: const Color(0xFF101014),
                  minChildSize: 0.08,
                  sheetController: sheetController,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final sheetFinder = find.byType(ExpandableQueueSheet);
    expect(sheetFinder, findsOneWidget);
    expect(sheetController.expandedSize, equals(0.50));
    expect(sheetController.minChildSize, equals(0.08));
  });

  testWidgets('tapping middle handle toggles between peek and expanded', (
    tester,
  ) async {
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

    player.updateQueue(
      [for (var i = 1; i <= 5; i++) _song('s$i', 'Song $i')],
      sourceId: 'test',
      sourceTitle: 'Test',
    );

    final sheetController = QueueSheetController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(child: Placeholder()),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ExpandableQueueSheet(
                  player: player,
                  controller: controller,
                  accent: const Color(0xFF101014),
                  minChildSize: 0.08,
                  sheetController: sheetController,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(sheetController.isExpanded, isFalse);

    // Tap to expand
    await tester.tap(find.text('UP NEXT'));
    await tester.pumpAndSettle();
    expect(sheetController.isExpanded, isTrue);
    expect(sheetController.size, closeTo(0.50, 0.01));

    // Tap to collapse
    await tester.tap(find.text('Up Next'));
    await tester.pumpAndSettle();
    expect(sheetController.isExpanded, isFalse);
    expect(sheetController.size, closeTo(0.08, 0.01));
  });

  testWidgets('selecting a song from the queue collapses the sheet', (
    tester,
  ) async {
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

    player.updateQueue(
      [for (var i = 1; i <= 5; i++) _song('s$i', 'Song $i')],
      sourceId: 'test',
      sourceTitle: 'Test',
    );

    final sheetController = QueueSheetController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(child: Placeholder()),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ExpandableQueueSheet(
                  player: player,
                  controller: controller,
                  accent: const Color(0xFF101014),
                  minChildSize: 0.08,
                  sheetController: sheetController,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Expand sheet first
    await tester.tap(find.text('UP NEXT'));
    await tester.pumpAndSettle();
    expect(sheetController.isExpanded, isTrue);

    // Tap song 3
    final songFinder = find.text('Song 3');
    expect(songFinder, findsOneWidget);
    await tester.tap(songFinder);
    await tester.pumpAndSettle();

    // Verify it collapsed to 0.08 and song is playing
    expect(sheetController.isExpanded, isFalse);
    expect(sheetController.size, closeTo(0.08, 0.01));
    expect(player.currentSong?.id, equals('s3'));
  });

  testWidgets('dragging upward past 30% threshold effortlessly expands the sheet', (
    tester,
  ) async {
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

    player.updateQueue(
      [for (var i = 1; i <= 5; i++) _song('s$i', 'Song $i')],
      sourceId: 'test',
      sourceTitle: 'Test',
    );

    final sheetController = QueueSheetController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(child: Placeholder()),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ExpandableQueueSheet(
                  player: player,
                  controller: controller,
                  accent: const Color(0xFF101014),
                  minChildSize: 0.08,
                  sheetController: sheetController,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(sheetController.isExpanded, isFalse);

    // Drag upward on the header by 120 pixels (less than half screen)
    await tester.drag(find.text('UP NEXT'), const Offset(0, -120));
    await tester.pumpAndSettle();

    // Verify it effortlessly expanded to 0.50
    expect(sheetController.isExpanded, isTrue);
    expect(sheetController.size, closeTo(0.50, 0.01));
  });
}
