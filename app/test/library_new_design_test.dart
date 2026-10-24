import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/screens/home_screen.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(String id, String title) => Song(
      id: id,
      title: title,
      fileName: '$title.mp3',
      size: 7 * 1024 * 1024,
      checksum: 'chk_$id',
      durationMs: 3 * 60 * 1000,
      addedAt: DateTime(2026, 1, 1),
    );

/// Settings > New design turns Library into search plus All, Playlists,
/// Downloads and History chips with an Add music button, and leaves the old
/// Library alone when off.
void main() {
  late Directory tempDir;

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return Directory.systemTemp.path;
    });
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('peerm-library-test');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  const phone = Size(430, 920);
  const wide = Size(1440, 900);

  Future<void> pump(
    WidgetTester tester, {
    Size size = phone,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppController controller;
    late PlayerService player;
    late IdentityService identity;
    late LibraryService library;
    late HistoryService history;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      identity = IdentityService(prefs);
      library = LibraryService()..debugBaseDirectory = tempDir;
      await library.init();
      library.setSongsForTesting([
        _song('a', 'Alpha'),
        _song('b', 'Bravo'),
        _song('c', 'Charlie'),
      ]);
      history = HistoryService(prefs);
      player = PlayerService(library, identity: identity, history: history);
      controller = AppController(
        identity: identity,
        library: library,
        player: player,
        youtube: YoutubeService(),
        history: history,
      );
      await controller.createPlaylist('Late night drive');
    });

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
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Finder chip(String name) => find.byKey(ValueKey('chip_$name'));

  for (final size in const [phone, wide]) {
    testWidgets('on at ${size.width.toInt()} px: search, chips, rows', (
      tester,
    ) async {
      await pump(tester, size: size);
      expect(tester.takeException(), isNull);
      expect(find.text('Search your music or online'), findsOneWidget);
      for (final name in ['all', 'playlists', 'downloads', 'history']) {
        expect(chip(name), findsOneWidget);
      }
      expect(find.text('New playlist'), findsOneWidget);
      expect(find.text('Liked songs'), findsOneWidget);
      expect(find.text('Late night drive'), findsOneWidget);
      expect(find.text('3 songs'), findsOneWidget);
      expect(find.text('Sort: Recent'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.textContaining('7.0 MB'), findsWidgets);
      expect(find.byKey(const ValueKey('add_music')), findsOneWidget);
      expect(find.byKey(const ValueKey('pill_favorites')), findsNothing);
    });
  }

  testWidgets('sideways, Add music moves into the header', (tester) async {
    await pump(tester, size: const Size(844, 390));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('add_music')), findsNothing);
    expect(find.byTooltip('Add music'), findsOneWidget);
  });

  testWidgets('Add music hides while the keyboard is up', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('add_music')), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add_music')), findsNothing);
  });

  testWidgets('chips pick playlists, songs or history', (tester) async {
    await pump(tester);

    await tester.tap(chip('playlists'));
    await tester.pumpAndSettle();
    expect(find.text('Late night drive'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);

    await tester.tap(chip('downloads'));
    await tester.pumpAndSettle();
    expect(find.text('Late night drive'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);

    await tester.ensureVisible(chip('history'));
    await tester.tap(chip('history'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('NOTHING PLAYED YET'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search filters the library and offers an online search', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'alp');
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Bravo'), findsNothing);
    expect(find.text('Late night drive'), findsNothing);
    expect(find.text('Search online for "alp"'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search_online')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('long-press selects with Add to playlist and Delete', (
    tester,
  ) async {
    await pump(tester);
    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();

    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byTooltip('Add to playlist'), findsOneWidget);
    expect(find.byTooltip('Delete selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('add_music')), findsNothing);

    await tester.tap(find.byTooltip('Cancel selection'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);
    expect(find.byKey(const ValueKey('add_music')), findsOneWidget);
  });
}
