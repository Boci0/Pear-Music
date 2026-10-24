import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/screens/home_feed_screen.dart';
import 'package:peerm_app/screens/home_screen.dart';
import 'package:peerm_app/screens/home_shell.dart';
import 'package:peerm_app/screens/playlist_detail_screen.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/player_theme.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/now_playing_panel.dart';
import 'package:peerm_app/widgets/player/theater_view.dart';
import 'package:peerm_app/widgets/wide_rail.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(String id, String title, {String? artwork}) => Song(
  id: id,
  title: title,
  artwork: artwork,
  fileName: '$id.mp3',
  size: 1024,
  checksum: 'chk_$id',
  addedAt: DateTime(2026, 1, 1),
);

/// New design on a Windows window: the wide rail, the player panel that
/// folds to a strip, and Theater mode. With it off the classic side rail and
/// pane stay.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  late AppController controller;

  Future<Widget> buildShell({bool playing = true}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final songs = [
      _song('a', 'Alpha'),
      _song('b', 'Bravo', artwork: 'https://example.com/bravo.jpg'),
    ];
    library.setSongsForTesting(songs);
    final history = HistoryService(prefs);
    final player = PlayerService(library, identity: identity, history: history);
    if (playing) {
      player.updateQueue(songs);
      player.currentSong = songs.first;
    }
    controller = AppController(
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
      child: const MaterialApp(home: HomeShell()),
    );
  }

  /// Runs [body] as a Windows window of [size]. The platform override has to
  /// be cleared before the test ends, so it is not left to a tear-down.
  Future<void> onWindows(
    WidgetTester tester,
    Size size,
    Future<void> Function() body,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// Theater keeps animating (the seek bar's wave, the lyrics), so it never
  /// settles; pump past the transitions instead.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Paints a rect in [color] (8-bit rounding allowed): a hover or press fill.
  PaintPattern paintsFill(Color color) => paints
    ..something((method, args) {
      if (method != #drawRect) return false;
      final c = (args.last as Paint).color;
      return (c.a - color.a).abs() < 0.005 &&
          (c.r - color.r).abs() < 0.005 &&
          (c.g - color.g).abs() < 0.005 &&
          (c.b - color.b).abs() < 0.005;
    });

  Finder railText(String text) => find.descendant(
    of: find.byKey(const ValueKey('wide_rail')),
    matching: find.text(text),
  );

  for (final size in const [Size(1440, 900), Size(1920, 1080)]) {
    testWidgets('opens on Home with the wide rail and the panel at $size', (
      tester,
    ) async {
      await onWindows(tester, size, () async {
        await tester.pumpWidget(await buildShell());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        expect(find.byType(WideRail), findsOneWidget);
        expect(find.byType(HomeFeedScreen), findsOneWidget);
        expect(tester.getSize(find.byType(WideRail)).width, WideRail.width);
        for (final label in ['Home', 'Explore', 'Library', 'History']) {
          expect(railText(label), findsOneWidget);
        }
        expect(railText('Liked songs'), findsOneWidget);
        expect(find.byKey(const ValueKey('pane_fold')), findsOneWidget);
        expect(find.text('Up next'), findsOneWidget);
        expect(find.text('NOW PLAYING'), findsNothing);
      });
    });
  }

  for (final size in const [Size(920, 900), Size(1100, 900)]) {
    testWidgets('a narrow window at $size folds the panel by itself', (
      tester,
    ) async {
      await onWindows(tester, size, () async {
        await tester.pumpWidget(await buildShell());
        await tester.pumpAndSettle();
        expect(find.byType(NowPlayingStrip), findsOneWidget);
        expect(find.byType(NowPlayingPanel), findsNothing);
        // The centre keeps room: rail and strip leave at least 480 px.
        final centre = size.width -
            WideRail.width -
            NowPlayingPanel.stripWidth -
            12;
        expect(centre, greaterThanOrEqualTo(480));
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('1280 wide keeps the open panel, and nothing playing fits narrow', (
    tester,
  ) async {
    await onWindows(tester, const Size(1280, 900), () async {
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    await onWindows(tester, const Size(920, 900), () async {
      await tester.pumpWidget(await buildShell(playing: false));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the panel folds to a strip and back', (tester) async {
    await onWindows(tester, const Size(1440, 900), () async {
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('pane_fold')));
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingStrip), findsOneWidget);
      expect(find.byType(NowPlayingPanel), findsNothing);
      expect(
        tester.getSize(find.byType(NowPlayingStrip)).width,
        NowPlayingPanel.stripWidth,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('pane_unfold')));
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingPanel), findsOneWidget);
    });
  });

  testWidgets('the cover opens Theater; L hides the lyrics, Escape leaves', (
    tester,
  ) async {
    await onWindows(tester, const Size(1440, 900), () async {
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('pane_theater')));
      await settle(tester);
      expect(find.byType(TheaterView), findsOneWidget);
      expect(find.byType(NowPlayingPanel), findsNothing);
      expect(
        tester.getSize(find.byType(WideRail)).width,
        WideRail.compactWidth,
      );
      expect(find.byKey(const ValueKey('theater_lyrics_a')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await settle(tester);
      expect(find.byKey(const ValueKey('theater_lyrics_a')), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(TheaterView), findsNothing);
      expect(find.byType(NowPlayingPanel), findsOneWidget);
      expect(tester.getSize(find.byType(WideRail)).width, WideRail.width);
    });
  });

  testWidgets('a rail section leaves Theater and opens its screen', (
    tester,
  ) async {
    await onWindows(tester, const Size(1440, 900), () async {
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pane_theater')));
      await settle(tester);

      await tester.tap(find.byTooltip('Library'));
      await settle(tester);
      expect(find.byType(TheaterView), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });

  testWidgets('rail search fills the Library search', (tester) async {
    await onWindows(tester, const Size(1440, 900), () async {
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('rail_search')), 'brav');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(HomeScreen),
          matching: find.widgetWithText(TextField, 'brav'),
        ),
        findsWidgets,
      );
    });
  });

  testWidgets('a rail playlist opens its page', (tester) async {
    await onWindows(tester, const Size(1440, 900), () async {
      final app = await buildShell();
      await controller.createPlaylist('Night drive');
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      await tester.tap(railText('Night drive'));
      await tester.pumpAndSettle();
      expect(find.byType(PlaylistDetailScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('an open playlist is still there after Theater', (tester) async {
    await onWindows(tester, const Size(1440, 900), () async {
      final app = await buildShell();
      await controller.createPlaylist('Night drive');
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      await tester.tap(railText('Night drive'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('pane_theater')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('theater_close')));
      await settle(tester);
      expect(find.byType(PlaylistDetailScreen), findsOneWidget);
    });
  });

  testWidgets('the control port can fold the panel and open Theater', (
    tester,
  ) async {
    await onWindows(tester, const Size(1440, 900), () async {
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();
      HomeShell.requestPanel(folded: true);
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingStrip), findsOneWidget);
      HomeShell.requestPanel(theater: true);
      await settle(tester);
      expect(find.byType(TheaterView), findsOneWidget);
      HomeShell.requestPanel(theater: false, folded: false);
      await settle(tester);
      expect(find.byType(NowPlayingPanel), findsOneWidget);
    });
  });

  testWidgets('nothing playing: the panel and strip still fit', (
    tester,
  ) async {
    await onWindows(tester, const Size(1440, 900), () async {
      await tester.pumpWidget(
        await buildShell(playing: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nothing playing'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Ctrl+K focuses the rail search with nothing focused', (
    tester,
  ) async {
    await onWindows(tester, const Size(1440, 900), () async {
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byKey(const ValueKey('rail_search')),
        matching: find.byType(EditableText),
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isFalse);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
    });
  });

  testWidgets('rail rows show hover ink and light the open playlist', (
    tester,
  ) async {
    await onWindows(tester, const Size(1440, 900), () async {
      final app = await buildShell();
      await controller.createPlaylist('Night drive');
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(railText('Liked songs')));
      await tester.pumpAndSettle();
      // The hover fill paints on the rail itself, not under it.
      expect(
        find.byKey(const ValueKey('wide_rail')),
        paintsFill(Colors.white.withValues(alpha: 0.07)),
      );

      final accent = Theme.of(
        tester.element(find.byType(WideRail)),
      ).colorScheme.primary;
      Color? color(String name) =>
          tester.widget<Text>(railText(name)).style?.color;
      expect(color('Night drive'), isNot(accent));

      await tester.tap(railText('Night drive'));
      await tester.pumpAndSettle();
      expect(color('Night drive'), accent);
      expect(color('Playlists'), isNot(accent));

      await tester.tap(railText('Liked songs'));
      await tester.pumpAndSettle();
      expect(color('Liked songs'), accent);
      expect(color('Night drive'), isNot(accent));

      // Back on the list, nothing but Playlists is lit.
      await tester.tap(railText('Playlists'));
      await tester.pumpAndSettle();
      expect(color('Liked songs'), isNot(accent));
      expect(color('Playlists'), accent);
    });
  });

  testWidgets('the panel tabs show hover ink on the panel', (tester) async {
    await onWindows(tester, const Size(1440, 900), () async {
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('Lyrics')));
      await tester.pumpAndSettle();
      final hover = Theme.of(tester.element(find.text('Lyrics'))).hoverColor;
      expect(find.byType(NowPlayingPanel), paintsFill(hover));
    });
  });

  testWidgets('the strip has previous, the title and a seek line', (
    tester,
  ) async {
    await onWindows(tester, const Size(1100, 900), () async {
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();
      final strip = find.byType(NowPlayingStrip);
      expect(strip, findsOneWidget);
      for (final tip in ['Previous', 'Next']) {
        expect(
          find.descendant(of: strip, matching: find.byTooltip(tip)),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(of: strip, matching: find.byTooltip('Alpha')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('strip_seek')), findsOneWidget);
      // No length known: a click on the line does nothing and breaks nothing.
      await tester.tap(find.byKey(const ValueKey('strip_seek')));
      await tester.pump();
      expect(tester.takeException(), isNull);

      // Too narrow for the panel: the cover opens Theater.
      await tester.tap(find.byKey(const ValueKey('strip_cover')));
      await settle(tester);
      expect(find.byType(TheaterView), findsOneWidget);
    });
  });

  testWidgets('with room, the strip cover opens the panel', (tester) async {
    await onWindows(tester, const Size(1440, 900), () async {
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pane_fold')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('strip_cover')));
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingPanel), findsOneWidget);
      expect(find.byType(TheaterView), findsNothing);
    });
  });

  testWidgets('clickable rows show the pointing hand', (tester) async {
    await onWindows(tester, const Size(1440, 900), () async {
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 1,
      );
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      MouseCursor cursorAt(Finder f) =>
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1)!;

      for (final row in ['Liked songs', 'Explore', 'Settings']) {
        await mouse.moveTo(tester.getCenter(railText(row)));
        await tester.pump();
        expect(cursorAt(railText(row)), SystemMouseCursors.click, reason: row);
      }

      await tester.tap(railText('Library'));
      await tester.pumpAndSettle();
      final song = find.descendant(
        of: find.byType(HomeScreen),
        matching: find.text('Bravo'),
      );
      await mouse.moveTo(tester.getCenter(song.first));
      await tester.pump();
      expect(cursorAt(song), SystemMouseCursors.click, reason: 'song row');
    });
  });

  testWidgets('rail thumbnails: a heart, a cover, an empty playlist icon', (
    tester,
  ) async {
    await onWindows(tester, const Size(1440, 900), () async {
      final app = await buildShell();
      final empty = await controller.createPlaylist('Empty one');
      final full = await controller.createPlaylist('With songs');
      await controller.addSongToPlaylist(full.id, 'b');
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('rail_liked_thumb')),
          matching: find.byIcon(Icons.favorite_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('rail_playlist_${empty.id}')),
          matching: find.byIcon(Icons.queue_music_rounded),
        ),
        findsOneWidget,
      );
      // The first song's cover (its network image).
      expect(
        find.descendant(
          of: find.byKey(ValueKey('rail_playlist_${full.id}')),
          matching: find.byKey(const ValueKey('pl_net_b')),
        ),
        findsOneWidget,
      );
    });
  });
}

