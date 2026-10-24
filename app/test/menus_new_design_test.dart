import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/import_export_sheet.dart';
import 'package:peerm_app/widgets/pear_sheet.dart';
import 'package:peerm_app/screens/playlists_screen.dart';
import 'package:peerm_app/widgets/player/playback_speed_dialog.dart';
import 'package:peerm_app/widgets/player/queue_bottom_sheet.dart';
import 'package:peerm_app/widgets/player/sleep_timer_dialog.dart';
import 'package:peerm_app/widgets/song_tile.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song() => Song(
      id: 's1',
      title: 'A rather long song title that needs to be cut off somewhere',
      fileName: 'a.mp3',
      size: 7 * 1024 * 1024,
      checksum: 'chk',
      durationMs: 3 * 60 * 1000,
      addedAt: DateTime(2026, 1, 1),
    );

/// With New design on the Android menus, sheets and dialogs use the Graphite
/// frame; with it off they stay as they were. Actions keep firing either way.
void main() {
  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return Directory.systemTemp.path;
    });
  });

  late AppController controller;
  late PlayerService player;

  /// Pumps a single button that runs [open] when tapped.
  Future<void> pump(
    WidgetTester tester, {
    required double width,
    required void Function(BuildContext) open,
    Widget? extra,
  }) async {
    tester.view.physicalSize = Size(width, 920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final history = HistoryService(prefs);
    player = PlayerService(library, identity: identity, history: history);
    controller = AppController(
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
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  TextButton(
                    onPressed: () => open(context),
                    child: const Text('OPEN'),
                  ),
                  ?extra,
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('OPEN'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final width in [320.0, 430.0]) {
    testWidgets('sleep timer sheet @$width', (tester) async {
      await pump(
        tester,
        width: width,
        open: (c) => showSleepTimerDialog(c, player),
      );
      await open(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(PearSheetChip), findsWidgets);
      // 15 minutes sets the timer and closes the sheet.
      await tester.tap(find.text('15 min'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(player.isSleepTimerActive, isTrue);
      player.cancelSleepTimer();
    });

    testWidgets('speed sheet @$width', (tester) async {
      await pump(
        tester,
        width: width,
        open: (c) => showPlaybackSpeedDialog(c, player),
      );
      await open(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(PearSheetChip), findsWidgets);
      await tester.tap(find.text('1.5x'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(player.speed, 1.5);
    });

    testWidgets('import and export sheet @$width', (tester) async {
      ImportExportAction? picked;
      await pump(
        tester,
        width: width,
        open: (c) async {
          picked = await showImportExportSheet(c, controller);
        },
      );
      await open(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(PearSheetRow), findsWidgets);
      await tester.tap(
        find.byKey(const ValueKey('import_export_import_playlists')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(picked, ImportExportAction.importPlaylists);
    });

    testWidgets('confirm dialog @$width', (tester) async {
      bool? result;
      await pump(
        tester,
        width: width,
        open: (c) async {
          result = await showDialog<bool>(
            context: c,
            builder: (ctx) => PearAlertDialog(
              title: const Text('Clear listening history?'),
              content: const Text('Recently played starts fresh.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Clear'),
                ),
              ],
            ),
          );
        },
      );
      await open(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Clear'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(result, isTrue);
    });

    testWidgets('playlist options sheet @$width', (tester) async {
      await pump(
        tester,
        width: width,
        open: (c) => showPlaylistOptionsFor(
          c,
          controller.playlists.first,
        ),
      );
      await tester.runAsync(() => controller.createPlaylist('Road trip'));
      await open(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Road trip'), findsOneWidget);
      expect(find.byType(PearSheetButton), findsNWidgets(2));
      expect(find.text('Export as .m3u8'), findsOneWidget);
      await tester.tap(find.text('Shuffle'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Road trip'), findsNothing);
    });

    testWidgets('queue title @$width', (tester) async {
      final sheet = QueueSheetController();
      await pump(
        tester,
        width: width,
        open: (_) {},
        extra: SizedBox(
          height: 800,
          child: Builder(
            builder: (context) => Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ExpandableQueueSheet(
                    player: context.read<PlayerService>(),
                    controller: context.read<AppController>(),
                    accent: Colors.teal,
                    minChildSize: 0.08,
                    sheetController: sheet,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('UP NEXT'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('QUEUE'), findsOneWidget);
      expect(find.text('Queue'), findsNothing);
    });

    testWidgets('song options sheet @$width', (tester) async {
      await pump(
        tester,
        width: width,
        open: (_) {},
        extra: SizedBox(
          height: 80,
          child: SongTile(song: _song()),
        ),
      );
      await tester.longPress(find.byType(SongTile));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.byType(PearSheetRow), findsWidgets);
      // The header shows the cover beside the title.
      final title = tester.getRect(find.text(_song().title).last);
      final sheetTitle = find.byType(PearSheetTitle);
      expect(
        find.descendant(of: sheetTitle, matching: find.byType(ClipRRect)),
        findsWidgets,
      );
      expect(title.left, greaterThan(tester.getRect(sheetTitle).left + 48));
      // Every row has an icon; Add to playlist ends in a chevron at the
      // right edge.
      for (final row in tester.widgetList<PearSheetRow>(
        find.byType(PearSheetRow),
      )) {
        expect(row.icon, isNotNull, reason: row.label);
      }
      final addRow = find.widgetWithText(PearSheetRow, 'Add to playlist');
      final chevron = find.descendant(
        of: addRow,
        matching: find.byIcon(Icons.chevron_right_rounded),
      );
      expect(
        tester.getRect(chevron).right,
        closeTo(tester.getRect(addRow).right - 20, 1),
      );
      // The three quick buttons are equal.
      final buttons = find.byType(PearSheetButton);
      expect(buttons, findsNWidgets(3));
      expect(
        tester.getSize(buttons.at(0)).width,
        closeTo(tester.getSize(buttons.at(2)).width, 0.5),
      );
      await tester.tap(find.text('Queue'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(player.queue.map((s) => s.id), contains('s1'));
    });
  }
}
