import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/screens/player_screen.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/player_theme.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/pear_page_route.dart';
import 'package:peerm_app/widgets/player/player_artwork.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Leaving the player must not switch the visualizer or lyrics off while the
/// close animation is still running: that swapped the artwork and rebuilt the
/// whole app mid-transition, which made the back animation stutter.
void main() {
  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return Directory.systemTemp.path;
    });
  });

  testWidgets('visualizer and lyrics stay put until the player has closed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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
    final song = Song(
      id: 's1',
      title: 'Song 1',
      fileName: 's1.mp3',
      size: 1024,
      checksum: 'chk_s1',
      addedAt: DateTime(2026, 1, 1),
    );
    player.updateQueue([song]);
    player.currentSong = song;

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        ChangeNotifierProvider<PlayerService>.value(value: player),
        ChangeNotifierProvider<IdentityService>.value(value: identity),
        ChangeNotifierProvider<LibraryService>.value(value: library),
        ChangeNotifierProvider<HistoryService>.value(value: history),
        ChangeNotifierProvider<PlayerTheme>.value(value: PlayerTheme(player)),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                PearPageRoute(builder: (_) => const PlayerScreen()),
              ),
              child: const Text('Open player'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open player'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await controller.updateSynthesizerBar(true);
    PlayerArtwork.showLyricsNotifier.value = true;
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // Mid-transition: nothing has been swapped yet.
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(identity.synthesizerBar, isTrue);
    expect(PlayerArtwork.isLyricsShowing, isTrue);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.byType(PlayerScreen), findsNothing);
    expect(identity.synthesizerBar, isFalse);
    expect(PlayerArtwork.isLyricsShowing, isFalse);
  });
}
