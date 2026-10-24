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
import 'package:peerm_app/theme/glass.dart';
import 'package:peerm_app/screens/home_screen.dart';
import 'package:peerm_app/widgets/pear_app_bar.dart';
import 'package:peerm_app/widgets/pear_sheet.dart';
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

/// Windows menus at 1440x900: the right-click menu, the app bar menu and the
/// library sort popup use the Graphite look with New design on, and stay the
/// plain Material ones with it off. Every action keeps firing.
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

  testWidgets('song right-click menu', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await pump(
      tester,
      width: 1440,
      open: (c) =>
          SongTile.showContextMenuFor(c, _song(), const Offset(600, 300)),
    );
    await open(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Add to queue'), findsOneWidget);
    expect(find.byIcon(Icons.queue_music_rounded), findsNothing);
    expect(find.byType(PopupMenuDivider), findsWidgets);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy title'));
    await tester.pumpAndSettle();
    expect(copied, _song().title);
    expect(find.text('Add to queue'), findsNothing);
  });

  testWidgets('app bar menu', (tester) async {
    String? picked;
    await pump(
      tester,
      width: 1440,
      open: (_) {},
      extra: PearMenuButton<String>(
        tooltip: 'More',
        icon: Icons.more_vert_rounded,
        onSelected: (v) => picked = v,
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Rename')),
        ],
      ),
    );
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.widget<PopupMenuButton<String>>(find.byType(PopupMenuButton<String>)).color,
      PearGlassTokens.angularPanel,
    );
    await tester.tap(find.text('Rename'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(picked, 'rename');
  });

  testWidgets('library sort popup', (tester) async {
    await pump(
      tester,
      width: 1440,
      open: (c) => showLibrarySortSheet(c, controller),
    );
    await open(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(PearSheetRow), findsNWidgets(3));
    await tester.tap(find.text('Title (A-Z)'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.sortOption, SortOption.title);
  });
}
