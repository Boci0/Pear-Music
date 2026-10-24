import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/screens/explore_screen.dart';
import 'package:peerm_app/screens/history_screen.dart';
import 'package:peerm_app/screens/home_screen.dart';
import 'package:peerm_app/screens/home_shell.dart';
import 'package:peerm_app/screens/player_screen.dart';
import 'package:peerm_app/screens/playlists_screen.dart';
import 'package:peerm_app/screens/settings_screen.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/player_theme.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/now_playing_panel.dart';
import 'package:peerm_app/widgets/pear_app_bar.dart';
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
/// the wide rail takes over.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return Directory.systemTemp.path;
        });
  });

  Future<Widget> buildShell({
    List<Song>? songs,
    List<Song>? queue,
    int? playIndex,
    AudioPlayer? audio,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    if (songs != null) library.setSongsForTesting(songs);
    final history = HistoryService(prefs);
    final player = PlayerService(
      library,
      identity: identity,
      history: history,
      player: audio,
    );
    if (queue != null) {
      player.updateQueue(queue);
      if (playIndex != null) player.currentSong = queue[playIndex];
    }
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

  testWidgets('a side system inset does not narrow the Now Playing pane', (
    tester,
  ) async {
    setViewport(tester, const Size(1400, 800));
    tester.view.padding = const FakeViewPadding(right: 60);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    final pane = tester.getSize(find.byKey(const ValueKey('now_playing_panel')));
    expect(pane.width, NowPlayingPanel.expandedPaneWidth);
  });

  testWidgets('wide windows use the wide rail and hide the bottom nav', (
    tester,
  ) async {
    setViewport(tester, const Size(1000, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('wide_rail')), findsOneWidget);
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

      expect(find.byKey(const ValueKey('wide_rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('now_playing_panel')), findsOneWidget);
      expect(find.byType(PlayerBar), findsNothing);
    },
  );

  testWidgets('the pane lists the whole queue with the playing track marked', (
    tester,
  ) async {
    setViewport(tester, const Size(1600, 900));
    final queue = [for (var i = 0; i < 3; i++) _song('q$i', 'Up Song $i')];
    await tester.pumpWidget(await buildShell(queue: queue, playIndex: 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('now_playing_panel')), findsOneWidget);
    expect(find.text('QUEUE'), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
    // The playing track stays in the list instead of being consumed, and the
    // upcoming tracks keep their queue positions. The playing title also
    // appears above the list, so it is matched loosely.
    expect(find.text('Up Song 0'), findsWidgets);
    expect(find.text('Up Song 1'), findsOneWidget);
    expect(find.text('Up Song 2'), findsOneWidget);
  });

  testWidgets('ticking playback widgets repaint on their own layer', (
    tester,
  ) async {
    // The pane's progress line and the status bar's time update 4 times a
    // second while a song plays. Each needs its own repaint boundary inside
    // its panel; otherwise every tick repaints the surrounding window chrome
    // (panel shadows included), which showed up as GPU use during playback.
    setViewport(tester, const Size(1600, 900));
    final queue = [for (var i = 0; i < 3; i++) _song('q$i', 'Up Song $i')];
    await tester.pumpWidget(await buildShell(queue: queue, playIndex: 0));
    await tester.pumpAndSettle();

    void expectOwnLayer(Finder ticking, Finder panel, String what) {
      expect(ticking, findsOneWidget, reason: what);
      final nearest = find
          .ancestor(of: ticking, matching: find.byType(RepaintBoundary))
          .first;
      expect(
        find.descendant(
          of: panel,
          matching: find.byWidget(tester.widget(nearest)),
        ),
        findsOneWidget,
        reason: '$what: its nearest repaint boundary must sit inside the panel',
      );
    }

    final statusBar = find.byKey(const ValueKey('pear_status_bar'));
    expectOwnLayer(
      find.descendant(of: statusBar, matching: find.textContaining('Up Song 0')),
      statusBar,
      'status bar playback time',
    );
  });

  testWidgets('a desktop shows the expanded pane and no mini player', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // Under the old 1250 breakpoint, where a desktop used to get the mini bar.
    setViewport(tester, const Size(1280, 800));
    final queue = [for (var i = 0; i < 3; i++) _song('d$i', 'Desk Song $i')];
    await tester.pumpWidget(await buildShell(queue: queue, playIndex: 0));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('now_playing_panel_expanded')),
      findsOneWidget,
    );
    expect(find.byType(PlayerBar), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('every tab shares one content width on a very wide window', (
    tester,
  ) async {
    setViewport(tester, const Size(1920, 1000));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    // All five tabs dock to the same content width, so no tab leaves a dead
    // strip between its content and the Now Playing pane. Playlists (1300),
    // Explore (1200) and Settings (960) used to cap at their own narrower
    // widths while the Library and History frames filled the region.
    final widths = <double>{
      for (final finder in <Finder>[
        find.byType(HomeScreen, skipOffstage: false),
        find.byType(PlaylistsScreen, skipOffstage: false),
        find.byType(ExploreScreen, skipOffstage: false),
        find.byType(HistoryScreen, skipOffstage: false),
        find.byType(SettingsScreen, skipOffstage: false),
      ])
        tester.getSize(finder).width,
    };
    expect(widths, hasLength(1));
    expect(widths.single, greaterThan(900));
  });

  testWidgets('landscape phones keep the phone shell despite the width', (
    tester,
  ) async {
    // A phone in landscape can be 900+ logical px wide but its short side is
    // far below tablet size, so it must not get the desktop chrome.
    setViewport(tester, const Size(900, 420));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('wide_rail')), findsNothing);
    expect(find.byKey(const ValueKey('pear_menu_bar')), findsNothing);
    expect(find.byKey(const ValueKey('landscape_rail')), findsOneWidget);
  });

  testWidgets('wide shell shows the classic menu bar and status bar', (
    tester,
  ) async {
    setViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pear_menu_bar')), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Playback'), findsOneWidget);
    expect(find.text('Help'), findsOneWidget);
    final statusBar = find.byKey(const ValueKey('pear_status_bar'));
    expect(statusBar, findsOneWidget);
    expect(
      find.descendant(of: statusBar, matching: find.textContaining('songs')),
      findsOneWidget,
    );
  });

  testWidgets('phone shell has no menu bar or status bar', (tester) async {
    setViewport(tester, const Size(400, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pear_menu_bar')), findsNothing);
    expect(find.byKey(const ValueKey('pear_status_bar')), findsNothing);
  });

  testWidgets('phone widths keep the bottom navigation shell', (tester) async {
    setViewport(tester, const Size(360, 720));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('wide_rail')), findsNothing);
    expect(find.byKey(const ValueKey('nav_bar')), findsOneWidget);
  });

  Future<void> openLibrary(WidgetTester tester) async {
    HomeShell.requestTab(0);
    await tester.pumpAndSettle();
  }

  testWidgets('wide library lays songs out in multiple columns', (
    tester,
  ) async {
    // The open player panel leaves the list about 1150 px here.
    setViewport(tester, const Size(1920, 1000));
    final songs = [for (var i = 0; i < 9; i++) _song('s$i', 'Song $i')];
    await tester.pumpWidget(await buildShell(songs: songs));
    await tester.pumpAndSettle();
    await openLibrary(tester);

    expect(find.byType(SliverGrid), findsOneWidget);
  });

  testWidgets('phone library stays a single column', (tester) async {
    setViewport(tester, const Size(400, 800));
    final songs = [for (var i = 0; i < 9; i++) _song('s$i', 'Song $i')];
    await tester.pumpWidget(await buildShell(songs: songs));
    await tester.pumpAndSettle();
    await openLibrary(tester);

    expect(find.byType(SliverGrid), findsNothing);
  });

  testWidgets('tapping a rail item switches the shell tab', (tester) async {
    setViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    final rail = find.byKey(const ValueKey('wide_rail'));
    await tester.tap(
      find.descendant(of: rail, matching: find.text('Playlists')).first,
    );
    await tester.pumpAndSettle();

    final shellStack = tester.widget<IndexedStack>(
      find.byType(IndexedStack).first,
    );
    expect(shellStack.index, 1);
  });

  testWidgets('the pear mark lives in the rail, not in every desktop tab title', (
    tester,
  ) async {
    setViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    expect(find.byType(PearMark), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('wide_rail')),
        matching: find.text('PEAR'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('phone tab titles name the tab in capitals by the stripe mark', (
    tester,
  ) async {
    setViewport(tester, const Size(400, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();
    await openLibrary(tester);

    final title = find.descendant(
      of: find.byType(HomeScreen),
      matching: find.byType(PearTabTitle),
    );
    expect(
      find.descendant(of: title, matching: find.text('LIBRARY')),
      findsOneWidget,
    );
  });

  testWidgets('very wide player swaps the queue peek for the queue panel', (
    tester,
  ) async {
    setViewport(tester, const Size(1500, 900));
    // The queue panel and peek are desktop-OS behaviour; tests run as Android.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final env = await buildPlayerApp();
    final first = _song('s1', 'Song 1');
    env.player.updateQueue([first, _song('s2', 'Song 2')]);
    env.player.currentSong = first;

    await tester.pumpWidget(env.app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    debugDefaultTargetPlatformOverride = null;

    expect(find.byKey(const ValueKey('queue_panel')), findsOneWidget);
    expect(find.byType(ExpandableQueueSheet), findsNothing);
    expect(find.text('Queue'), findsOneWidget);
  });

  testWidgets('player below the panel threshold keeps the queue peek sheet', (
    tester,
  ) async {
    setViewport(tester, const Size(1000, 800));
    // The queue panel and peek are desktop-OS behaviour; tests run as Android.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final env = await buildPlayerApp();
    final first = _song('s1', 'Song 1');
    env.player.updateQueue([first, _song('s2', 'Song 2')]);
    env.player.currentSong = first;

    await tester.pumpWidget(env.app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    debugDefaultTargetPlatformOverride = null;

    expect(find.byKey(const ValueKey('queue_panel')), findsNothing);
    expect(find.byType(ExpandableQueueSheet), findsOneWidget);
  });

  testWidgets(
    'widening the window hands the full-screen player to the expanded pane',
    (tester) async {
      setViewport(tester, const Size(500, 900));
      final queue = [for (var i = 0; i < 3; i++) _song('w$i', 'Wide Song $i')];
      await tester.pumpWidget(await buildShell(queue: queue, playIndex: 0));
      await tester.pumpAndSettle();

      // Phone width: the mini player opens the full-screen player page.
      await tester.tap(find.byType(PlayerBar));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsOneWidget);

      // Widen past the pane breakpoint (short side >= 600 so the test
      // platform gets the wide shell too).
      tester.view.physicalSize = const Size(1400, 900);
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsNothing);
      expect(
        find.byKey(const ValueKey('now_playing_panel_expanded')),
        findsOneWidget,
      );
    },
  );

  testWidgets('switching tabs fades the body in', (tester) async {
    setViewport(tester, const Size(400, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    FadeTransition bodyFade() => tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byType(IndexedStack).first,
            matching: find.byType(FadeTransition),
          )
          .first,
    );

    expect(bodyFade().opacity.value, 1.0);

    await tester.tap(
      find.byKey(const ValueKey('nav_tab_Library')),
    );
    await tester.pump();
    // The new tab starts faded out, then reaches full opacity.
    expect(bodyFade().opacity.value, lessThan(1.0));
    await tester.pumpAndSettle();
    expect(bodyFade().opacity.value, 1.0);

    final shellStack = tester.widget<IndexedStack>(
      find.byType(IndexedStack).first,
    );
    expect(shellStack.index, 0);
  });

  testWidgets('the Playback menu offers transport with shortcut hints', (
    tester,
  ) async {
    setViewport(tester, const Size(1280, 800));
    final queue = [_song('s1', 'Song 1')];
    await tester.pumpWidget(await buildShell(queue: queue, playIndex: 0));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Playback'));
    await tester.pumpAndSettle();

    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Previous Track'), findsOneWidget);
    expect(find.text('Next Track'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Next Track'), findsNothing);
  });
}
