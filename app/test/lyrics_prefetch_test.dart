import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/lyrics_service.dart';
import 'package:peerm_app/services/player_service.dart';

/// Lyrics used to be looked up only when the Lyrics tab opened, so with the
/// tab closed `lyrics_cache/<id>.lrc` was never written and desktop
/// companions reading it waited forever. A song that starts playing now
/// looks its lyrics up and saves them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final sandbox = Directory.systemTemp.createTempSync('peerm_lyrics_prefetch_');
  setUpAll(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => sandbox.path,
    );
    // A stand-in engine that plays every song.
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.just_audio.methods'),
      (call) async {
        if (call.method != 'init') return <String, Object?>{};
        final id = (call.arguments as Map)['id'] as String;
        MockStreamHandlerEventSink? events;
        messenger.setMockStreamHandler(
          EventChannel('com.ryanheise.just_audio.events.$id'),
          MockStreamHandler.inline(onListen: (_, sink) => events = sink),
        );
        messenger.setMockStreamHandler(
          EventChannel('com.ryanheise.just_audio.data.$id'),
          MockStreamHandler.inline(onListen: (_, _) {}),
        );
        messenger.setMockMethodCallHandler(
          MethodChannel('com.ryanheise.just_audio.methods.$id'),
          (call) async {
            if (call.method != 'load') return <String, Object?>{};
            events?.success({
              'processingState': 3, // ready
              'updateTime': DateTime.now().millisecondsSinceEpoch,
              'updatePosition': 0,
              'bufferedPosition': 0,
              'duration': 60000000,
              'currentIndex': 0,
            });
            return {'duration': 60000000};
          },
        );
        return <String, Object?>{};
      },
    );
  });
  tearDown(() {
    LyricsService.onlineLyricsForTesting = null;
    LyricsService.clearMemoryCache();
  });
  tearDownAll(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> eventually(bool Function() done) async {
    for (var i = 0; i < 50 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('a song that starts playing saves its lyrics with the tab closed',
      () async {
    final library = LibraryService();
    await library.init();
    final song = (await library.addLocalFiles([
      File(p.join(sandbox.path, 'sung.mp3'))
        ..writeAsBytesSync(List.filled(4096, 1)),
    ])).single;
    var lookups = 0;
    LyricsService.onlineLyricsForTesting = (_, {duration}) async {
      lookups++;
      return '[00:01.00] Hello';
    };

    final player = PlayerService(library);
    await player.playSong(song).timeout(const Duration(seconds: 5));
    final saved = File(p.join(
      sandbox.path,
      'lyrics_cache',
      '${song.id.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')}.lrc',
    ));
    await eventually(saved.existsSync);
    expect(saved.existsSync(), isTrue);
    expect(saved.readAsStringSync(), startsWith('[00:01.00] Hello'));

    // The Lyrics tab opening afterwards does not look them up again.
    expect((await LyricsService.getLyrics(song)).single.text, 'Hello');
    expect(lookups, 1);
  });

  test('a failing lyrics lookup does not stop the song', () async {
    final library = LibraryService();
    await library.init();
    final song = (await library.addLocalFiles([
      File(p.join(sandbox.path, 'unsung.mp3'))
        ..writeAsBytesSync(List.filled(4096, 2)),
    ])).single;
    var asked = false;
    LyricsService.onlineLyricsForTesting = (_, {duration}) async {
      asked = true;
      throw const SocketException('offline');
    };

    final player = PlayerService(library);
    await player.playSong(song).timeout(const Duration(seconds: 5));
    await eventually(() => asked);
    expect(asked, isTrue);
    expect(player.currentSong?.id, song.id);
    expect(player.playbackError, isNull);
  });
}
