import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/screens/playlist_detail_screen.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(String id, String title, int minutes) => Song(
      id: 'stream_$id',
      title: title,
      fileName: '$title.m4a',
      size: 0,
      checksum: 'chk_$id',
      sourceDeviceId: 'stream',
      durationMs: minutes * 60 * 1000,
      addedAt: DateTime(2026, 1, 1),
    );

/// Settings > New design swaps the playlist page for the cover header with
/// Play, Shuffle and a filter, and leaves the old page alone when off.
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
    tempDir = await Directory.systemTemp.createTemp('peerm-pl-detail-test');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<AppController> pumpScreen(
    WidgetTester tester, {
    required Size size,
    List<Song>? songs,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppController controller;
    late String playlistId;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final identity = IdentityService(prefs);
      final library = LibraryService()..debugBaseDirectory = tempDir;
      await library.init();
      final history = HistoryService(prefs);
      controller = AppController(
        identity: identity,
        library: library,
        player: PlayerService(library, identity: identity, history: history),
        youtube: YoutubeService(),
        history: history,
      );
      final pl = await controller.createPlaylist('Late night drive');
      playlistId = pl.id;
      for (final s in songs ??
          [
            _song('a', 'Alpha', 25),
            _song('b', 'Bravo', 30),
            _song('c', 'Charlie', 7),
          ]) {
        await controller.addSongToPlaylist(pl.id, s.id, song: s);
      }
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: PlaylistDetailScreen(playlistId: playlistId),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  test('summary counts songs and adds the known length', () {
    expect(playlistSummary([]), '0 songs');
    expect(playlistSummary([_song('a', 'A', 0)]), '1 song');
    expect(playlistSummary([_song('a', 'A', 59)]), '1 song · 59 min');
    expect(
      playlistSummary([_song('a', 'A', 60), _song('b', 'B', 60)]),
      '2 songs · 2 hr',
    );
    expect(
      playlistSummary([_song('a', 'A', 61), _song('b', 'B', 1)]),
      '2 songs · 1 hr 2 min',
    );
  });

  testWidgets('on, phone: header, sort line, filter and rows', (tester) async {
    await pumpScreen(tester, size: const Size(430, 920));
    expect(tester.takeException(), isNull);
    expect(find.text('PLAYLIST'), findsOneWidget);
    expect(find.text('Late night drive'), findsOneWidget);
    expect(find.text('3 songs · 1 hr 2 min'), findsOneWidget);
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(find.byTooltip('Shuffle'), findsOneWidget);
    expect(find.byTooltip('More'), findsOneWidget);
    expect(find.text('SORTED BY  CUSTOM ORDER'), findsOneWidget);
    expect(find.text('Play all'), findsNothing);
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(3));
    expect(
      tester.getSize(find.byKey(const ValueKey('playlist_cover_blank'))),
      const Size(132, 132),
    );

    // The filter hides behind its button on a phone.
    expect(find.byKey(const ValueKey('playlist_filter')), findsNothing);
    await tester.tap(find.text('Filter'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('playlist_filter')),
      'brav',
    );
    await tester.pump();
    expect(find.text('Bravo'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
    // The header still counts the whole playlist.
    expect(find.text('3 songs · 1 hr 2 min'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('playlist_filter')),
      'zzz',
    );
    await tester.pump();
    expect(find.textContaining('No songs in this playlist match'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('on, phone: dragging a row reorders the playlist',
      (tester) async {
    final controller =
        await pumpScreen(tester, size: const Size(430, 920));
    final handle = find.byIcon(Icons.drag_handle_rounded).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 15));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    final ids = controller.playlists.single.songIds;
    expect(ids.first, 'stream_b');
    expect(ids.toSet(), {'stream_a', 'stream_b', 'stream_c'});
  });

  testWidgets('on, wide: big header and an open filter field',
      (tester) async {
    await pumpScreen(tester, size: const Size(1440, 900));
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('playlist_cover_blank'))),
      const Size(200, 200),
    );
    expect(find.text('PLAY'), findsOneWidget);
    expect(find.byKey(const ValueKey('playlist_filter')), findsOneWidget);
    expect(find.text('SORTED BY  CUSTOM ORDER'), findsNothing);
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(3));
  });

  testWidgets('on, wide: table columns with an offline mark per song', (
    tester,
  ) async {
    await pumpScreen(tester, size: const Size(1440, 900));
    expect(tester.takeException(), isNull);
    for (final label in ['TITLE', 'ARTIST', 'OFFLINE', 'SIZE']) {
      expect(find.text(label), findsOneWidget);
    }
    // The test songs all play from the internet.
    expect(find.text('ONLINE'), findsNWidgets(3));
  });

  testWidgets('on, phone: no table columns', (tester) async {
    await pumpScreen(tester, size: const Size(430, 920));
    expect(find.text('OFFLINE'), findsNothing);
    expect(find.text('ONLINE'), findsNothing);
  });

  testWidgets('on: an empty playlist fits at both sizes', (tester) async {
    for (final size in const [Size(320, 640), Size(1440, 900)]) {
      await pumpScreen(tester, size: size, songs: const []);
      expect(tester.takeException(), isNull);
      expect(find.text('0 songs'), findsOneWidget);
      expect(find.text('THIS PLAYLIST IS EMPTY'), findsOneWidget);
    }
  });

  testWidgets('on, narrow phone: a long name does not overflow',
      (tester) async {
    await pumpScreen(
      tester,
      
      size: const Size(320, 640),
      songs: [
        _song(
          'x',
          'A very long song title that goes on and on past the row width',
          4,
        ),
      ],
    );
    expect(tester.takeException(), isNull);
  });
}
