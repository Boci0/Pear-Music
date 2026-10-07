import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_search_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/theme/tokens.dart';
import 'package:peerm_app/widgets/song_tile.dart';
import 'package:peerm_app/widgets/youtube_song_tile.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guards the song list pitch: every song card must want exactly
/// [PearRow.extent] of height. The lists and grids hand rows that extent as a
/// tight constraint, so a card that grows past it is silently squeezed (the
/// 64 px card once painted at 53 px in 61 px rows and no test noticed).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppController> makeController() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final library = LibraryService();
    return AppController(
      identity: IdentityService(prefs),
      library: library,
      player: PlayerService(library),
      youtube: YoutubeService(),
    );
  }

  Future<void> pumpLoose(
    WidgetTester tester,
    AppController controller,
    Widget tile,
  ) {
    return tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              // The test font (Ahem) is wider than real fonts; keep the text
              // from overflowing the row horizontally.
              data: const MediaQueryData(textScaler: TextScaler.linear(0.2)),
              // Loose height, so the tile reports the height it wants.
              child: Column(children: [tile]),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('SongTile wants exactly the row extent', (tester) async {
    final controller = await makeController();
    await pumpLoose(
      tester,
      controller,
      SongTile(
        song: Song(
          id: 's1',
          title: 'Song 1',
          fileName: 's1.mp3',
          size: 100,
          checksum: 'chk_s1',
          addedAt: DateTime(2026, 1, 1),
        ),
      ),
    );
    expect(tester.getSize(find.byType(SongTile)).height, PearRow.extent);
  });

  testWidgets('YouTubeSongTile wants exactly the row extent', (tester) async {
    final controller = await makeController();
    await pumpLoose(
      tester,
      controller,
      const YouTubeSongTile(
        result: YouTubeSearchResult(
          videoId: 'v1',
          title: 'Song 1',
          author: 'Artist',
        ),
      ),
    );
    expect(tester.getSize(find.byType(YouTubeSongTile)).height, PearRow.extent);
  });
}
