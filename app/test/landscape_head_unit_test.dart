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

/// Android car head units (1024x600, 800x480) and landscape phones run
/// landscape. Neither the shell nor the player may overflow at those sizes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => Directory.systemTemp.path,
        );
  });

  Future<Widget> build(Widget home) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final history = HistoryService(prefs);
    final player = PlayerService(library, identity: identity, history: history);
    final songs = [
      for (var i = 0; i < 3; i++)
        Song(
          id: 's$i',
          title: 'Head Unit Song $i',
          fileName: 's$i.mp3',
          size: 1024,
          checksum: 'chk_$i',
          addedAt: DateTime(2026, 1, 1),
        ),
    ];
    player.updateQueue(songs);
    player.currentSong = songs.first;
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
        ChangeNotifierProvider<PlayerTheme>.value(
          value: PlayerTheme(player),
        ),
      ],
      child: MaterialApp(home: home),
    );
  }

  for (final size in const [
    Size(1024, 600),
    Size(800, 480),
    Size(667, 375),
    Size(640, 360),
    Size(800, 360),
    Size(844, 390),
    Size(915, 412),
  ]) {
    for (final entry in <String, Widget>{
      'shell': const HomeShell(),
      'player': const PlayerScreen(),
    }.entries) {
      testWidgets('${entry.key} lays out at ${size.width}x${size.height}', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.pumpWidget(await build(entry.value));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expect(tester.takeException(), isNull);

        if (entry.key == 'shell' &&
            !HomeShell.usesWideShell(size) &&
            size.height < 500) {
          // Short phone shell: the nav bar shares a row with the mini player
          // instead of stacking under it.
          final nav = tester.getSize(find.byKey(const ValueKey('nav_bar')));
          expect(nav.width, lessThanOrEqualTo(size.width * 0.5));
        }

        if (entry.key == 'player') {
          // Landscape has no pull-up queue sheet, so Up Next is a labelled
          // button on the player itself.
          await tester.tap(find.byKey(const ValueKey('up_next_button')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(find.byKey(const ValueKey('queue_panel')), findsOneWidget);
          expect(tester.takeException(), isNull);
        }

        if (entry.key == 'shell') {
          // Visit every tab, in the phone shell's nav bar or the side rail.
          for (final tab in const [
            'Playlists',
            'Explore',
            'History',
            'Settings',
            'Library',
          ]) {
            await tester.tap(find.text(tab).first);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 600));
            expect(tester.takeException(), isNull, reason: tab);
          }
        }
      });
    }
  }
}
