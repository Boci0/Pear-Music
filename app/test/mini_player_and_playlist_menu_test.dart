import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/screens/playlists_screen.dart';
import 'package:peerm_app/screens/settings_screen.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/player/player_controls.dart';
import 'package:peerm_app/widgets/player/stream_quality_info_dialog.dart';
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

class _FakePlayerVolumeService extends ChangeNotifier implements PlayerService {
  double _volume = 0.5;

  @override
  double get volume => _volume;

  @override
  Future<void> setVolume(double value) async {
    _volume = value.clamp(0.0, 1.0);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

  group('PlayerVolumeRow and PlayerVolumeSlider thick pill', () {
    testWidgets('renders volume percentage inside the capsule and updates on volume changes', (tester) async {
      final player = _FakePlayerVolumeService();
      await player.setVolume(0.75);

      await tester.pumpWidget(
        ChangeNotifierProvider<PlayerService>.value(
          value: player,
          child: const MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  child: PlayerVolumeRow(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('75%'), findsWidgets);

      await player.setVolume(0.40);
      await tester.pumpAndSettle();
      expect(find.text('40%'), findsWidgets);

      // Tap mute via left volume icon area
      final sliderFinder = find.byType(PlayerVolumeSlider);
      expect(sliderFinder, findsOneWidget);
      await tester.tapAt(tester.getTopLeft(sliderFinder) + const Offset(20, 18));
      await tester.pumpAndSettle();
      expect(player.volume, 0.0);
      expect(find.text('0%'), findsWidgets);

      // Verify the capsule height is 36 px
      final sliderBox = tester.renderObject<RenderBox>(sliderFinder);
      expect(sliderBox.size.height, 36.0);
    });
  });

  group('Simplified Audio Pipeline and Stream Diagnostics', () {
    test('IdentityService removes legacy network preference keys', () async {
      SharedPreferences.setMockInitialValues({
        'peerm_streaming_quality': 'high',
        'peerm_online_lyrics': false,
        'peerm_preload_upcoming': false,
        'peerm_online_artwork': false,
      });
      final prefs = await SharedPreferences.getInstance();
      IdentityService(prefs);

      expect(prefs.containsKey('peerm_streaming_quality'), isFalse);
      expect(prefs.containsKey('peerm_online_lyrics'), isFalse);
      expect(prefs.containsKey('peerm_preload_upcoming'), isFalse);
      expect(prefs.containsKey('peerm_online_artwork'), isFalse);
    });

    test('StreamCacheManager getAudioFormatArg returns optimal universal format selector', () {
      expect(
        StreamCacheManager.getAudioFormatArg(),
        'ba/ba*/bestaudio/b/best',
      );
    });

    testWidgets('SettingsScreen does not display legacy Data & Internet customization section', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final identity = IdentityService(prefs);
      final library = LibraryService();
      final player = PlayerService(library, identity: identity);
      final controller = AppController(
        identity: identity,
        library: library,
        player: player,
        youtube: YoutubeService(),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: controller),
            ChangeNotifierProvider.value(value: player),
          ],
          child: const MaterialApp(
            home: SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('DATA & INTERNET'), findsNothing);
      expect(find.text('Streaming Audio Quality'), findsNothing);
      expect(find.text('Fetch Online Lyrics'), findsNothing);
      expect(find.text('Preload Next Track'), findsNothing);
      expect(find.text('Online Album Artwork'), findsNothing);
    });

    testWidgets('StreamQualityInfoButton renders simple icon and opens read-only info dialog', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final identity = IdentityService(prefs);
      final library = LibraryService();
      final player = PlayerService(library, identity: identity);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerService>.value(value: player),
            ChangeNotifierProvider<IdentityService?>.value(value: identity),
          ],
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(
                actions: [
                  StreamQualityInfoButton(player: player),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Clean info icon rendered without badge
      expect(find.byType(StreamQualityInfoButton), findsOneWidget);
      expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);

      // Tap info button to open StreamQualityInfoDialog
      await tester.tap(find.byType(StreamQualityInfoButton));
      await tester.pumpAndSettle();

      expect(find.text('Info'), findsOneWidget);
      expect(find.text('TRACK & FILE PROPERTIES'), findsOneWidget);
      expect(find.text('STREAM & RESOLVER DIAGNOSTICS'), findsOneWidget);
    });
  });
}
