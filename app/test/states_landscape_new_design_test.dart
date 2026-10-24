import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/screens/home_shell.dart';
import 'package:peerm_app/screens/player_screen.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/player_theme.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Batch 5: the empty states, and the phone held sideways (a left rail in
/// place of the dock, a compact Library header, the split player). Off, the
/// app is as before.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  const phone = Size(430, 920);
  const sideways = Size(920, 430);
  const wide = Size(1440, 900);

  Future<Widget> build({
    bool playing = false,
    Widget home = const HomeShell(),
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final history = HistoryService(prefs);
    final player = PlayerService(library, identity: identity, history: history);
    if (playing) {
      final songs = [
        for (var i = 0; i < 3; i++)
          Song(
            id: 's$i',
            title: 'Sideways Song $i',
            fileName: 's$i.mp3',
            size: 1024,
            checksum: 'chk_$i',
            addedAt: DateTime(2026, 1, 1),
          ),
      ];
      player.updateQueue(songs);
      player.currentSong = songs.first;
    }
    final controller = AppController(
      identity: identity,
      library: library,
      player: player,
      youtube: YoutubeService(),
      history: history,
    );
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        ChangeNotifierProvider<PlayerService>.value(value: player),
        ChangeNotifierProvider<IdentityService>.value(value: identity),
        ChangeNotifierProvider<LibraryService>.value(value: library),
        ChangeNotifierProvider<HistoryService>.value(value: history),
        ChangeNotifierProvider<PlayerTheme>.value(value: PlayerTheme(player)),
      ],
      child: MaterialApp(theme: ThemeData.dark(), home: home),
    );
  }

  Future<void> pump(WidgetTester tester, Size size, Widget app) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final size in const [phone, wide]) {
    testWidgets('empty library and playlists at ${size.width.toInt()} px', (
      tester,
    ) async {
      await pump(tester, size, await build());
      HomeShell.requestTab(0);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('YOUR MUSIC LIBRARY IS EMPTY'), findsOneWidget);
      expect(find.text('ADD MUSIC'), findsWidgets);
      HomeShell.requestTab(1);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('NO PLAYLISTS CREATED YET'), findsOneWidget);
      expect(find.text('NEW PLAYLIST'), findsOneWidget);
      expect(find.byKey(const ValueKey('landscape_rail')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('player with nothing loaded', (tester) async {
    await pump(
      tester,
      phone,
      await build(home: const PlayerScreen()),
    );
    expect(find.text('NOTHING IS PLAYING'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sideways, on: a left rail replaces the dock', (tester) async {
    await pump(tester, sideways, await build(playing: true));
    expect(find.byKey(const ValueKey('landscape_rail')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav_bar')), findsNothing);
    final rail = find.byKey(const ValueKey('landscape_rail'));
    Finder inRail(String t) =>
        find.descendant(of: rail, matching: find.text(t));
    for (final label in ['Home', 'Explore', 'Library']) {
      expect(inRail(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);

    // Library: search and chips share one row.
    await tester.tap(inRail('Library'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    final chipY = tester.getCenter(find.byKey(const ValueKey('chip_all'))).dy;
    final fieldY = tester.getCenter(find.byType(TextField)).dy;
    expect((chipY - fieldY).abs(), lessThan(8));

    // The cover on the rail opens the split player.
    await tester.tap(find.byKey(const ValueKey('landscape_rail_cover')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byTooltip('Queue'), findsWidgets);
    expect(find.text('Cover'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

}
