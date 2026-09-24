import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/screens/home_screen.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/song_tile.dart';
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

/// Desktop conventions: right-click context menus and the persistent search
/// field in the wide library header.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return Directory.systemTemp.path;
    });
  });

  Future<({AppController controller, LibraryService library, PlayerService player})>
      createEnvironment() async {
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
    return (controller: controller, library: library, player: player);
  }

  Widget buildHarness({
    required AppController controller,
    required PlayerService player,
    required Widget child,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        ChangeNotifierProvider<PlayerService>.value(value: player),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  testWidgets('right click on a song row opens the desktop context menu', (
    tester,
  ) async {
    final env = await createEnvironment();
    final song = _song('local_1', 'Local File');
    env.library.setSongsForTesting([song]);

    await tester.pumpWidget(
      buildHarness(
        controller: env.controller,
        player: env.player,
        child: SongTile(song: song),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SongTile)),
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Start Radio'), findsOneWidget);
    expect(find.text('Add to queue'), findsOneWidget);
    expect(find.text('Remove from library'), findsOneWidget);
  });

  testWidgets('wide library header keeps the search field visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final env = await createEnvironment();
    await tester.pumpWidget(
      buildHarness(
        controller: env.controller,
        player: env.player,
        child: const HomeScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Search library...'), findsOneWidget);
  });

  testWidgets('phone library header hides the search field behind the icon', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final env = await createEnvironment();
    await tester.pumpWidget(
      buildHarness(
        controller: env.controller,
        player: env.player,
        child: const HomeScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Search library...'), findsNothing);
    expect(find.byIcon(Icons.search), findsOneWidget);
  });
}
