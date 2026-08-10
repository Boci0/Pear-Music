import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/signaling_service.dart';
import 'package:peerm_app/services/sync_service.dart';
import 'package:peerm_app/services/youtube_service.dart';

/// A plain [AppController] (no overriding) so the real state reconciliation in
/// [_applyPairings] runs, driven through the [AppController.applyPairings]
/// test hook.
class _TestController extends AppController {
  _TestController({
    required super.identity,
    required super.library,
    required super.signaling,
    required super.sync,
    required super.player,
    required super.youtube,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LibraryService library;
  late _TestController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    tempDir = await Directory.systemTemp.createTemp('peerm-unpair-test');
    library = LibraryService()..debugBaseDirectory = tempDir;
    await library.init();
    final signaling = SignalingService(identity);
    final sync = SyncService(identity: identity, library: library);
    final player = PlayerService(library);
    controller = _TestController(
      identity: identity,
      library: library,
      signaling: signaling,
      sync: sync,
      player: player,
      youtube: YoutubeService(),
    );
  });

  tearDown(() async {
    // Windows can transiently hold a file handle (e.g. a file delete still in
    // flight from an un-awaited cleanup), which makes a recursive delete fail.
    // Retry so the teardown never fails on a timing race.
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  /// Adds a song as if it had been received from [sourceDeviceId].
  Future<void> addSharedSong(String id, String sourceDeviceId) async {
    final inc = library.incomingFile(id);
    inc.writeAsBytesSync(List.filled(100, 1));
    await library.addReceivedSong(
      id: id,
      title: 'Shared $id',
      fileName: '$id.mp3',
      size: 100,
      checksum: 'checksum-$id',
      sourceDeviceId: sourceDeviceId,
    );
  }

  test('shared songs are removed when their source is no longer paired', () async {
    await addSharedSong('song-1', 'peer-1');
    await library.addLocalFiles([
      File('${tempDir.path}/my-own.mp3')..writeAsBytesSync(List.filled(50, 2)),
    ]);
    expect(library.songs.length, 2);

    // Server says no pairings → the shared song must go, the local one stays.
    await controller.applyPairings([]);

    expect(library.songs.length, 1);
    expect(library.songs.single.sourceDeviceId, isNull);
  });

  test('shared songs stay while the source is still paired (even offline)', () async {
    await addSharedSong('song-1', 'peer-1');
    expect(library.songs.length, 1);

    // peer-1 is still paired but offline → its songs must NOT be removed.
    await controller.applyPairings([
      {'deviceId': 'peer-1', 'deviceName': 'Phone', 'online': false},
    ]);

    expect(library.songs.length, 1);
    expect(library.songs.single.sourceDeviceId, 'peer-1');
  });

  test('multiple unpaired sources are all cleaned up', () async {
    await addSharedSong('song-a', 'peer-1');
    await addSharedSong('song-b', 'peer-2');
    expect(library.songs.length, 2);

    // Only peer-1 is still paired; peer-2's song must be removed.
    await controller.applyPairings([
      {'deviceId': 'peer-1', 'deviceName': 'Phone', 'online': true},
    ]);

    expect(library.songs.length, 1);
    expect(library.songs.single.sourceDeviceId, 'peer-1');
  });
}
