import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_search_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/youtube_song_tile.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The phone shell is about 780 px wide. A one column list there must keep the
/// meta line ("Online · artist") under the title, not in a right hand column
/// that truncated the artist while leaving a gap beside the title.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpTile(WidgetTester tester, double width) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final library = LibraryService();
    final controller = AppController(
      identity: IdentityService(prefs),
      library: library,
      player: PlayerService(library),
      youtube: YoutubeService(),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(0.2)),
              child: Column(
                children: [
                  SizedBox(
                    width: width,
                    child: const YouTubeSongTile(
                      result: YouTubeSearchResult(
                        videoId: 'v1',
                        title: 'Song 1',
                        author: 'Artist',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('at phone shell width the meta sits under the title', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpTile(tester, 740);
    final title = tester.getTopLeft(find.text('Song 1'));
    final meta = tester.getTopLeft(find.text('Online · Artist'));
    expect(meta.dy, greaterThan(title.dy));
    // Only the small broadcast icon sits before the meta text.
    expect(meta.dx, lessThan(title.dx + 30));
  });

  testWidgets('on a very wide row the meta moves to its own column', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpTile(tester, 1200);
    final title = tester.getTopLeft(find.text('Song 1'));
    final meta = tester.getTopLeft(find.text('Online · Artist'));
    expect(meta.dx, greaterThan(title.dx + 100));
  });
}
