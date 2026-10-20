import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:just_audio/just_audio.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/screens/history_screen.dart';
import 'package:peerm_app/screens/home_shell.dart';
import 'package:peerm_app/screens/player_screen.dart';
import 'package:peerm_app/services/artwork_palette.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/lyrics_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/player_theme.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/player/lyrics_view.dart';
import 'package:peerm_app/widgets/player/player_artwork.dart';
import 'package:peerm_app/widgets/player/queue_bottom_sheet.dart';
import 'package:peerm_app/widgets/player_bar.dart';
import 'package:peerm_app/widgets/song_tile.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression tests for the UI audit fixes. They run the real widgets on
/// mocked services, the way the other screen tests do.

Song _song(
  String id,
  String title, {
  int addedDays = 0,
  String? artwork,
  String? sourceDeviceId,
}) =>
    Song(
      id: id,
      title: title,
      fileName: '$id.mp3',
      size: 1024,
      checksum: 'chk_$id',
      artwork: artwork,
      sourceDeviceId: sourceDeviceId,
      addedAt: DateTime(2026, 1, 1).add(Duration(days: addedDays)),
    );

/// A solid-colour image encoded as a base64 JPEG, the format the Song
/// artwork field carries.
String _solidArtwork(Color color, {int size = 64}) {
  final image = img.Image(width: size, height: size);
  img.fill(
    image,
    color: img.ColorRgb8(
      (color.r * 255).round(),
      (color.g * 255).round(),
      (color.b * 255).round(),
    ),
  );
  return base64Encode(img.encodeJpg(image));
}

class _Env {
  _Env(this.controller, this.player);

  final AppController controller;
  final PlayerService player;
}

Future<_Env> _makeEnv(
  List<Song> songs, {
  List<Song>? queue,
  int? playIndex,
}) async {
  SharedPreferences.setMockInitialValues({'peerm_style': 'glass'});
  final prefs = await SharedPreferences.getInstance();
  final identity = IdentityService(prefs);
  final library = LibraryService();
  library.setSongsForTesting(songs);
  final history = HistoryService(prefs);
  final player = PlayerService(library, identity: identity, history: history);
  if (queue != null && queue.isNotEmpty) {
    player.updateQueue(queue, sourceId: 'test', sourceTitle: 'Test');
    if (playIndex != null) player.currentSong = queue[playIndex];
  }
  final controller = AppController(
    identity: identity,
    library: library,
    player: player,
    youtube: YoutubeService(),
    history: history,
  );
  return _Env(controller, player);
}

Widget _shell(_Env env) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: env.controller),
      ChangeNotifierProvider<PlayerService>.value(value: env.player),
      ChangeNotifierProvider<PlayerTheme>.value(
        value: PlayerTheme(env.player),
      ),
    ],
    child: const MaterialApp(home: HomeShell()),
  );
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// A player parked at [position_] whose position stream a test drives.
class _FakeEngine extends AudioPlayer {
  _FakeEngine() : super(handleAudioSessionActivation: false);

  Duration position_ = Duration.zero;
  final StreamController<Duration> positions = StreamController.broadcast();

  @override
  Duration get position => position_;

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  bool get playing => false;

  @override
  Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) =>
      positions.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return Directory.systemTemp.path;
    });
  });

  testWidgets(
      'a resize with a dialog open keeps the dialog, and a later build hands '
      'the player over to the pane', (tester) async {
    // Desktop makes the popups plain dialogs, and makes the wide shell switch
    // on at 900 px so the pane breakpoint is reachable in the test viewport.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    _setViewport(tester, const Size(500, 900));

    final queue = [
      _song('w1', 'Wide One'),
      _song('w2', 'Wide Two'),
      _song('w3', 'Wide Three'),
    ];
    final env = await _makeEnv(queue, queue: queue, playIndex: 0);
    await tester.pumpWidget(_shell(env));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PlayerBar));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Playback speed'));
    await tester.pumpAndSettle();
    expect(find.text('Playback Speed'), findsOneWidget);

    // Widen past the pane breakpoint while the dialog is up.
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpAndSettle();

    // The hand-off must not pop the dialog (it used to pop whatever route was
    // on top) and must not latch itself off.
    expect(find.text('Playback Speed'), findsOneWidget);
    expect(find.byType(PlayerScreen), findsOneWidget);

    // Close the dialog, then a later build retries the hand-off.
    await tester.tap(find.text('1.25x'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1401, 900);
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsNothing);
    expect(
      find.byKey(const ValueKey('pane_content_expanded')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    // Leave the platform override clean before the binding checks its
    // invariants at the end of the test body.
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the queue sheet paints no per-frame shadow or clip layer',
      (tester) async {
    final env = await _makeEnv(
      const [],
      queue: [for (var i = 1; i <= 5; i++) _song('q$i', 'Queue $i')],
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
                  player: env.player,
                  controller: env.controller,
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

    final sheet = find.byType(ExpandableQueueSheet);

    // A blurred shadow on a panel whose height animates is rasterised again on
    // every frame, which is the GPU pattern the glass shadow history warns
    // about.
    expect(
      find.descendant(
        of: sheet,
        matching: find.byWidgetPredicate((widget) {
          if (widget is! Container) return false;
          final decoration = widget.decoration;
          return decoration is BoxDecoration &&
              (decoration.boxShadow?.isNotEmpty ?? false);
        }),
      ),
      findsNothing,
      reason: 'no animated blurred box shadow on the sheet',
    );

    // The same goes for a rounded clip rebuilt from a changing size/radius.
    expect(
      find.descendant(
        of: sheet,
        matching: find.byWidgetPredicate(
          (widget) => widget is Container && widget.clipBehavior != Clip.none,
        ),
      ),
      findsNothing,
      reason: 'no clip layer on the animating sheet',
    );

    // It still works: expanding shows the list.
    await tester.tap(find.text('UP NEXT'));
    await tester.pumpAndSettle();
    expect(sheetController.isExpanded, isTrue);
    expect(find.text('Queue 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typing filters the library after the debounce, clearing is immediate',
      (tester) async {
    _setViewport(tester, const Size(1280, 800));
    final songs = [for (var i = 1; i <= 5; i++) _song('s$i', 'Song $i')];
    final env = await _makeEnv(songs);
    await tester.pumpWidget(_shell(env));
    await tester.pumpAndSettle();

    expect(find.text('Song 1'), findsOneWidget);
    final field = find.byType(TextField);
    expect(field, findsOneWidget);

    await tester.enterText(field, 'Song 5');
    await tester.pump();
    // One frame later the debounce has not fired, so the list is untouched.
    expect(find.widgetWithText(SongTile, 'Song 1'), findsOneWidget);
    expect(find.widgetWithText(SongTile, 'Song 5'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.widgetWithText(SongTile, 'Song 5'), findsOneWidget);
    expect(find.widgetWithText(SongTile, 'Song 1'), findsNothing);
    expect(tester.takeException(), isNull);

    // An empty field is applied at once, so the list never looks stuck behind
    // an empty search box.
    await tester.enterText(field, '');
    await tester.pump();
    expect(find.widgetWithText(SongTile, 'Song 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library rows keep the list key on the row child and sort by title',
      (tester) async {
    _setViewport(tester, const Size(400, 900));
    final songs = [
      _song('a1', 'Alpha', addedDays: 1),
      _song('b2', 'Bravo', addedDays: 2),
      _song('c3', 'Charlie', addedDays: 3),
    ];
    final env = await _makeEnv(songs);
    await tester.pumpWidget(_shell(env));
    await tester.pumpAndSettle();

    // The key sits on the widget the sliver builds, so findChildIndexCallback
    // can match it when the list is re-ordered.
    for (final id in ['a1', 'b2', 'c3']) {
      expect(
        tester.widget(find.byKey(ValueKey(id))),
        isA<RepaintBoundary>(),
        reason: '$id should be keyed on the list child',
      );
    }

    // Default sort is date added, newest first.
    expect(
      tester.getTopLeft(find.text('Charlie')).dy,
      lessThan(tester.getTopLeft(find.text('Alpha')).dy),
    );

    await env.controller.setSortOption(SortOption.title);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Alpha')).dy,
      lessThan(tester.getTopLeft(find.text('Bravo')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Bravo')).dy,
      lessThan(tester.getTopLeft(find.text('Charlie')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('history rows keep the list key on the row child', (tester) async {
    _setViewport(tester, const Size(1280, 1000));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final local = _song('local_1', 'Local File');
    library.setSongsForTesting([local]);
    final history = HistoryService(prefs);
    final player = PlayerService(library, identity: identity, history: history);
    final controller = AppController(
      identity: identity,
      library: library,
      player: player,
      youtube: YoutubeService(),
      history: history,
    );
    history.record(local);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(value: controller),
          ChangeNotifierProvider<PlayerService>.value(value: player),
          ChangeNotifierProvider<HistoryService>.value(value: history),
        ],
        child: const MaterialApp(home: HistoryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Local File'), findsOneWidget);
    expect(
      tester.widget(find.byKey(const ValueKey('local_1'))),
      isA<RepaintBoundary>(),
      reason: 'the history sliver child carries the identity key',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pane queue marks the playing row by song identity',
      (tester) async {
    _setViewport(tester, const Size(1600, 900));
    final queue = [
      _song('q1', 'Queue One'),
      _song('q2', 'Queue Two'),
      _song('q3', 'Queue Three'),
    ];
    final env = await _makeEnv(queue, queue: queue, playIndex: 1);
    await tester.pumpWidget(_shell(env));
    await tester.pumpAndSettle();

    final pane = find.byKey(const ValueKey('now_playing_panel'));
    expect(
      find.descendant(of: pane, matching: find.text('2 / 3')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: pane,
        matching: find.byIcon(Icons.graphic_eq_rounded),
      ),
      findsOneWidget,
      reason: 'the playing row is marked',
    );

    // A song that is not in the queue has no row to mark. The old code used
    // the retained queue index and lit up an unrelated row.
    env.player.currentSong = _song('outside', 'Outside');
    env.player.notifyListeners();
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: pane,
        matching: find.byIcon(Icons.graphic_eq_rounded),
      ),
      findsNothing,
      reason: 'no queue row matches the current song id',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('lyrics are not looked up while the card has never been shown',
      (tester) async {
    const lrc = '''
[00:00.00] Line one
[00:05.00] Line two
[00:10.00] Line three
''';
    final song = _song('lazy_lyrics', 'Lazy Lyrics Song');
    LyricsService.setLyricsForTesting(song.id, lrc);
    addTearDown(LyricsService.clearMemoryCache);

    final engine = _FakeEngine();
    final player = PlayerService(LibraryService(), player: engine);

    Widget harness({required bool visible}) {
      return MaterialApp(
        home: Center(
          child: SizedBox(
            width: 320,
            height: 320,
            child: LyricsView(
              song: song,
              player: player,
              size: 320,
              isVisible: visible,
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(harness(visible: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text('Line one'),
      findsNothing,
      reason: 'hidden lyrics must not be fetched before the card is opened',
    );

    await tester.pumpWidget(harness(visible: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Line one'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the player card paints artwork decoded by the async path',
      (tester) async {
    // Nothing in the byte cache, as after an eviction or a memory compaction:
    // build must not decode base64 synchronously.
    ArtworkPalette.clearMemoryCaches();
    final song = _song(
      'art_song',
      'Art Song',
      artwork: _solidArtwork(const Color(0xFFD01828)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              height: 160,
              child: PlayerArtwork(song: song, size: 160),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.byType(Image),
      findsOneWidget,
      reason: 'the future builder fills the cover in',
    );

    await tester.pumpWidget(const SizedBox());
  });
}
