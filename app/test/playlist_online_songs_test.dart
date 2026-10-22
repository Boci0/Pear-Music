import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _stream(String videoId) => Song(
      id: 'stream_$videoId',
      title: 'Online $videoId',
      fileName: 'stream_$videoId.m4a',
      size: 0,
      checksum: 'stream_$videoId',
      sourceDeviceId: 'stream',
      addedAt: DateTime(2026, 10, 22),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an online song in a playlist survives the known-songs cache limit',
      () async {
    SharedPreferences.setMockInitialValues({});
    final identity = IdentityService(await SharedPreferences.getInstance());
    final library = LibraryService();
    final controller = AppController(
      identity: identity,
      library: library,
      player: PlayerService(library, identity: identity),
      youtube: YoutubeService(),
    );

    final kept = _stream('keptKeptKe1');
    final playlist = await controller.createPlaylist('Mine');
    await controller.addSongToPlaylist(playlist.id, kept.id, song: kept);

    // Radio and history register every song they see; the cache holds 1000.
    await identity.registerOnlineSongs([
      for (var i = 0; i < 1100; i++) _stream('filler${i.toString().padLeft(5, '0')}'),
    ]);

    expect(controller.findSongById(kept.id)?.title, 'Online keptKeptKe1',
        reason: 'a playlist member must not fall out of the cache');
    expect(identity.knownOnlineSongs.length, lessThanOrEqualTo(1001));
    expect(controller.findSongById('stream_filler00000'), isNull,
        reason: 'unprotected old songs are still dropped first');
  });
}
