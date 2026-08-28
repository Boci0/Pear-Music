import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/signaling_server.dart';
import 'package:peerm_app/services/signaling_service.dart';
import 'package:peerm_app/services/sync_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/player/player_drawer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guards the fixed scroll-extent optimization: every drawer queue row must
/// render at exactly the itemExtent height (64.0). If a future ListTile change
/// (new text line, larger trailing) grows the row beyond the extent, this
/// test fails instead of the rows silently overlapping.
Song _song(String id, String title) => Song(
  id: id,
  title: title,
  fileName: '$id.mp3',
  size: 100,
  checksum: 'chk_$id',
  addedAt: DateTime(2026, 1, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('drawer queue rows render at the fixed 64.0 itemExtent', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final player = PlayerService(library);
    final controller = AppController(
      identity: identity,
      library: library,
      signaling: SignalingService(identity),
      sync: SyncService(identity: identity, library: library),
      player: player,
      youtube: YoutubeService(),
      server: SignalingServer(port: 8091),
    );
    player.updateQueue(
      [for (var i = 1; i <= 8; i++) _song('s$i', 'Song $i')],
      sourceId: 'library',
      sourceTitle: 'Library',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Align(
              // The test font (Ahem) renders wider than real fonts; shrink the
              // text scale so the drawer header row fits its 304px width.
              alignment: Alignment.centerLeft,
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(0.4)),
                child: PlayerDrawer(
                  controller: controller,
                  player: player,
                  currentSong: player.queue.first,
                  activePlaylistId: null,
                  onActivePlaylistChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tiles = find.byType(ListTile);
    expect(tiles, findsWidgets);
    for (final element in tiles.evaluate()) {
      expect(
        element.size!.height,
        64.0,
        reason: 'drawer queue rows must render at the fixed itemExtent',
      );
    }

    // Content-stable, duplicate-safe keys: shrinking the queue must relayout
    // cleanly (a key collision would throw during rebuild).
    player.updateQueue(
      [for (var i = 1; i <= 4; i++) _song('s$i', 'Song $i')],
      sourceId: 'library',
      sourceTitle: 'Library',
    );
    await tester.pumpAndSettle();
    expect(tiles, findsWidgets);
  });
}
