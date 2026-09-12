import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/screens/playlists_screen.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/player_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _createSong(String id, String title, {String? sourceDeviceId}) => Song(
      id: id,
      title: title,
      fileName: '$id.mp3',
      size: 1024,
      checksum: 'chk_$id',
      sourceDeviceId: sourceDeviceId,
      addedAt: DateTime(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerBar Option 1 minimalist title and status', () {
    testWidgets('displays only track title during normal playback without subtitle', (tester) async {
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

      final song = _createSong('s1', 'Rap God - Eminem');
      player.updateQueue([song], sourceId: 'src1', sourceTitle: 'Hip Hop');
      player.currentSong = song;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: controller),
            ChangeNotifierProvider.value(value: player),
          ],
          child: const MaterialApp(
            home: Scaffold(
              bottomNavigationBar: PlayerBar(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Rap God - Eminem'), findsOneWidget);
      expect(find.text('Rap God'), findsNothing);
      expect(find.text('Eminem'), findsNothing);
      expect(find.text('Playing on this device'), findsNothing);
      expect(find.text('Hip Hop'), findsNothing);
    });

    testWidgets('displays transient status when buffering', (tester) async {
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

      final song = _createSong('s2', 'Bohemian Rhapsody');
      player.updateQueue([song]);
      player.currentSong = song;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: controller),
            ChangeNotifierProvider.value(value: player),
          ],
          child: const MaterialApp(
            home: Scaffold(
              bottomNavigationBar: PlayerBar(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bohemian Rhapsody'), findsOneWidget);
      expect(find.text('Buffering track...'), findsNothing);

      // Trigger buffering state
      player.setBufferingForTesting(true);
      await tester.pump();

      expect(find.text('Buffering track...'), findsOneWidget);
    });
  });

  group('PlaylistsScreen bottom sheet menu', () {
    testWidgets('tapping 3-dots opens bottom sheet modal with play, shuffle, rename, and delete options', (tester) async {
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

      await library.createPlaylist('Road Trip Mix');

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: controller),
            ChangeNotifierProvider.value(value: player),
          ],
          child: const MaterialApp(
            home: PlaylistsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Road Trip Mix'), findsOneWidget);

      final moreBtn = find.byTooltip('Playlist options');
      expect(moreBtn, findsOneWidget);
      await tester.tap(moreBtn);
      await tester.pumpAndSettle();

      // Verify bottom sheet content
      expect(find.text('Play all'), findsOneWidget);
      expect(find.text('Shuffle'), findsOneWidget);
      expect(find.text('Rename playlist'), findsOneWidget);
      expect(find.text('Delete playlist'), findsOneWidget);
    });
  });
}
