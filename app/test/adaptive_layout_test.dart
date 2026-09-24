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
import 'package:peerm_app/widgets/player/queue_bottom_sheet.dart';
import 'package:peerm_app/widgets/player_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(String id, String title) => Song(
  id: id,
  title: title,
  fileName: '$id.mp3',
  size: 1024,
  checksum: 'chk_$id',
  addedAt: DateTime(2026, 1, 1),
);

/// Guards the adaptive shell: below 900 logical px the phone shell with the
/// bottom navigation bar is used; at 900 px and above the desktop shell with
/// the side rail takes over.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return Directory.systemTemp.path;
        });
  });

  Future<Widget> buildShell({List<Song>? songs}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    if (songs != null) library.setSongsForTesting(songs);
    final history = HistoryService(prefs);
    final player = PlayerService(library, identity: identity, history: history);
    final controller = AppController(
      identity: identity,
      library: library,
      player: player,
      youtube: YoutubeService(),
      history: history,
    );
    final playerTheme = PlayerTheme(player);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        ChangeNotifierProvider<PlayerService>.value(value: player),
        ChangeNotifierProvider<IdentityService>.value(value: identity),
        ChangeNotifierProvider<LibraryService>.value(value: library),
        ChangeNotifierProvider<HistoryService>.value(value: history),
        ChangeNotifierProvider<PlayerTheme>.value(value: playerTheme),
      ],
      child: const MaterialApp(home: HomeShell()),
    );
  }

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<({Widget app, PlayerService player})> buildPlayerApp() async {
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
    final playerTheme = PlayerTheme(player);
    final app = MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        ChangeNotifierProvider<PlayerService>.value(value: player),
        ChangeNotifierProvider<IdentityService>.value(value: identity),
        ChangeNotifierProvider<LibraryService>.value(value: library),
        ChangeNotifierProvider<HistoryService>.value(value: history),
        ChangeNotifierProvider<PlayerTheme>.value(value: playerTheme),
      ],
      child: const MaterialApp(home: PlayerScreen()),
    );
    return (app: app, player: player);
  }

  testWidgets('wide windows use the side rail and hide the bottom nav', (
    tester,
  ) async {
    setViewport(tester, const Size(1000, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('side_rail')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav_bar')), findsNothing);
    expect(find.byType(PlayerBar), findsOneWidget);
    expect(find.byKey(const ValueKey('now_playing_panel')), findsNothing);
  });

  testWidgets(
    '1250+ windows show the Now Playing pane instead of the mini bar',
    (tester) async {
      setViewport(tester, const Size(1500, 900));
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('side_rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('now_playing_panel')), findsOneWidget);
      expect(find.byType(PlayerBar), findsNothing);
    },
  );

  testWidgets('phone widths keep the bottom navigation shell', (tester) async {
    setViewport(tester, const Size(360, 720));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('side_rail')), findsNothing);
    expect(find.byKey(const ValueKey('nav_bar')), findsOneWidget);
  });

  testWidgets('wide library lays songs out in multiple columns', (
    tester,
  ) async {
    setViewport(tester, const Size(1600, 900));
    final songs = [for (var i = 0; i < 9; i++) _song('s$i', 'Song $i')];
    await tester.pumpWidget(await buildShell(songs: songs));
    await tester.pumpAndSettle();

    expect(find.byType(SliverGrid), findsOneWidget);
  });

  testWidgets('phone library stays a single column', (tester) async {
    setViewport(tester, const Size(400, 800));
    final songs = [for (var i = 0; i < 9; i++) _song('s$i', 'Song $i')];
    await tester.pumpWidget(await buildShell(songs: songs));
    await tester.pumpAndSettle();

    expect(find.byType(SliverGrid), findsNothing);
  });

  testWidgets('tapping a rail item switches the shell tab', (tester) async {
    setViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    final rail = find.byKey(const ValueKey('side_rail'));
    await tester.tap(
      find.descendant(of: rail, matching: find.text('Playlists')),
    );
    await tester.pumpAndSettle();

    final shellStack = tester.widget<IndexedStack>(
      find.byType(IndexedStack).first,
    );
    expect(shellStack.index, 1);
  });

  testWidgets('very wide player swaps the queue peek for the Up Next panel', (
    tester,
  ) async {
    setViewport(tester, const Size(1500, 900));
    final env = await buildPlayerApp();
    final first = _song('s1', 'Song 1');
    env.player.updateQueue([first, _song('s2', 'Song 2')]);
    env.player.currentSong = first;

    await tester.pumpWidget(env.app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const ValueKey('queue_panel')), findsOneWidget);
    expect(find.byType(ExpandableQueueSheet), findsNothing);
    expect(find.text('Up Next'), findsOneWidget);
  });

  testWidgets('player below the panel threshold keeps the queue peek sheet', (
    tester,
  ) async {
    setViewport(tester, const Size(1000, 800));
    final env = await buildPlayerApp();
    final first = _song('s1', 'Song 1');
    env.player.updateQueue([first, _song('s2', 'Song 2')]);
    env.player.currentSong = first;

    await tester.pumpWidget(env.app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const ValueKey('queue_panel')), findsNothing);
    expect(find.byType(ExpandableQueueSheet), findsOneWidget);
  });
}
