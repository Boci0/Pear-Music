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
import 'package:peerm_app/services/screen_awake.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/player/player_artwork.dart';
import 'package:peerm_app/widgets/player/player_controls.dart';
import 'package:peerm_app/widgets/player/player_stage_body.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings > New player swaps the upright phone player for the redesigned
/// one (view tabs, left-aligned title, tools row) and leaves it alone when off.
void main() {
  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return Directory.systemTemp.path;
    });
  });

  tearDown(PlayerArtwork.closeLyrics);

  Future<IdentityService> pumpPlayer(
    WidgetTester tester, {
    Size size = const Size(480, 900),
  }) async {
    tester.view.physicalSize = size;
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

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(value: controller),
          ChangeNotifierProvider<PlayerService>.value(value: player),
          ChangeNotifierProvider<IdentityService>.value(value: identity),
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<HistoryService>.value(value: history),
          ChangeNotifierProvider<PlayerTheme>.value(
            value: PlayerTheme(player),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    return identity;
  }

  testWidgets('switch, cover, title and quiet tools replace the volume row', (
    tester,
  ) async {
    await pumpPlayer(tester);
    expect(find.byType(PlayerStageBody), findsOneWidget);
    expect(find.byType(PlayerVolumeRow), findsNothing);

    // The top bar: close, the Cover / Lyrics switch, the more menu. No
    // spaced-capital read-outs anywhere.
    expect(find.byTooltip('Close player'), findsOneWidget);
    expect(find.byTooltip('More'), findsOneWidget);
    for (final caps in ['PLAYING FROM', 'NOW PLAYING', 'COVER', 'QUEUE']) {
      expect(find.text(caps), findsNothing, reason: caps);
    }
    // No picture for this song, so no Video in the switch.
    expect(find.text('Cover'), findsOneWidget);
    expect(find.text('Video'), findsNothing);
    expect(find.text('Lyrics'), findsOneWidget);
    for (final tool in [
      'Queue',
      'Sleep timer',
      'Playback speed',
      'Start Radio mix',
    ]) {
      expect(find.byTooltip(tool), findsOneWidget, reason: tool);
    }

    // The cover spans the content width and the title starts at its edge.
    final cover = tester.getRect(find.byType(PlayerArtworkHero));
    expect(cover.width, closeTo(480 - 48, 1));
    final title = tester.getRect(find.text('Song 1'));
    expect(title.left, closeTo(cover.left, 1));
    expect(title.top, greaterThan(cover.bottom));

    // The more menu holds the song's options and the track info.
    await tester.tap(find.byTooltip('More'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Song options'), findsOneWidget);
    expect(find.text('Track info'), findsOneWidget);
  });

  testWidgets('the Lyrics and Cover tabs switch the picture', (tester) async {
    await pumpPlayer(tester);
    await tester.tap(find.text('Lyrics'));
    // Let the switch animation run to the end.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(PlayerArtwork.isLyricsShowing, isTrue);
    // Lyrics get the full height instead of the cover's square.
    expect(find.byType(StageLyricsPanel), findsOneWidget);
    expect(find.byType(PlayerArtworkHero), findsNothing);
    // Keep screen on (Lyrics Options, on by default) still works here.
    expect(ScreenAwake.isOn, isTrue);

    await tester.tap(find.text('Cover'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(PlayerArtwork.isLyricsShowing, isFalse);
  });

  // The tools must end above the Up Next bar (62 px plus the inset), not
  // scroll under it: the first phone run hid them there.
  for (final size in const [Size(360, 740), Size(392, 800), Size(480, 900)]) {
    testWidgets('everything fits above the Up Next bar at $size', (
      tester,
    ) async {
      await pumpPlayer(tester, size: size);
      expect(tester.takeException(), isNull);
      final toolsBottom = tester.getRect(find.byTooltip('Queue')).bottom;
      expect(toolsBottom, lessThanOrEqualTo(size.height - 62));
      expect(find.byTooltip('Show lyrics'), findsNothing);

      // The full-height lyrics fit the same space.
      await tester.tap(find.text('Lyrics'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byTooltip('Queue')).bottom,
        lessThanOrEqualTo(size.height - 62),
      );
    });
  }

  test('an old New design switch value is cleared on start', () async {
    for (final saved in [true, false]) {
      SharedPreferences.setMockInitialValues({'peerm_new_player': saved});
      final prefs = await SharedPreferences.getInstance();
      IdentityService(prefs);
      expect(prefs.containsKey('peerm_new_player'), isFalse);
    }
  });
}
