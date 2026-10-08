import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';

/// A song that cannot be opened for playback must stay in the library, file and
/// all. Opening can fail for reasons that have nothing to do with the file (the
/// audio backend not started, the output device busy), and removing the entry
/// deletes the user's copy for good.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Directory.systemTemp.createTempSync('peerm_local_failure_');
  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => sandbox.path);
    // A stand-in audio backend that cannot open anything.
    const audio = MethodChannel('com.ryanheise.just_audio.methods');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audio, (call) async {
      if (call.method == 'init') {
        throw PlatformException(code: 'abort', message: 'Cannot open file');
      }
      return <String, Object?>{};
    });
  });
  tearDownAll(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a file the player cannot open stays in the library and is explained', () async {
    final library = LibraryService();
    await library.init();
    // Not audio: opening it fails, standing in for any open failure.
    final source = File(p.join(sandbox.path, 'not_really_audio.mp3'))
      ..writeAsBytesSync(List.filled(4096, 1));
    final added = await library.addLocalFiles([source]);
    expect(added, hasLength(1));
    final song = added.single;
    final onDisk = library.songFile(song);
    expect(onDisk.existsSync(), isTrue);

    final player = PlayerService(library);
    await player.playSong(song);
    // Let any background removal run before looking.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      library.songs.any((s) => s.id == song.id),
      isTrue,
      reason: 'the song must not be removed from the library',
    );
    expect(onDisk.existsSync(), isTrue, reason: 'the file must not be deleted');
    expect(onDisk.lengthSync(), 4096);
    expect(player.playbackError?.song.id, song.id);
    expect(player.playbackError?.message, contains('still in your library'));
  });

  test('a ghost entry whose file is gone is still cleaned up', () async {
    final library = LibraryService();
    await library.init();
    final source = File(p.join(sandbox.path, 'ghost.mp3'))
      ..writeAsBytesSync(List.filled(4096, 2));
    final song = (await library.addLocalFiles([source])).single;
    library.songFile(song).deleteSync();

    final player = PlayerService(library);
    await player.playSong(song);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(library.songs.any((s) => s.id == song.id), isFalse,
        reason: 'an entry with no file behind it is dead weight');
  });
}
