import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';

/// The desktop engine never answers a load of a file it can neither play nor
/// reject (a video download with no sound track). When that was the first song
/// after startup, every later song waited behind it and nothing played until
/// a restart. The stuck song must fail with an explanation and the next must
/// play.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final sandbox = Directory.systemTemp.createTempSync('peerm_stuck_open_');
  final calls = <String>[];
  setUpAll(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => sandbox.path,
    );
    // A stand-in engine: loads of the silent file never answer, others play.
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
            calls.add(call.method);
            if (call.method != 'load') return <String, Object?>{};
            // The library renames files, so the stuck one is told by its type.
            if ('${call.arguments}'.contains('.mp4')) {
              return Completer<Map<String, Object?>>().future;
            }
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
  tearDownAll(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a song the engine never answers does not block the next one', () async {
    PlayerService.fileOpenTimeout = const Duration(milliseconds: 300);
    final library = LibraryService();
    await library.init();
    final silent = (await library.addLocalFiles([
      File(p.join(sandbox.path, 'silent.mp4'))..writeAsBytesSync(List.filled(4096, 1)),
    ])).single;
    final fine = (await library.addLocalFiles([
      File(p.join(sandbox.path, 'fine.mp3'))..writeAsBytesSync(List.filled(4096, 2)),
    ])).single;

    final player = PlayerService(library);
    // The first song after startup, as in the report.
    await player.playSong(silent).timeout(const Duration(seconds: 5));
    expect(player.playbackError?.song.id, silent.id);
    expect(library.songs.any((s) => s.id == silent.id), isTrue,
        reason: 'a song that would not open stays in the library');

    calls.clear();
    await player.playSong(fine).timeout(const Duration(seconds: 5));
    expect(player.currentSong?.id, fine.id);
    expect(player.playbackError, isNull);
    // play() is sent without waiting.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(calls, containsAllInOrder(['load', 'play']));
    });

  test('skipping a stuck song before it times out plays the next one', () async {
    PlayerService.fileOpenTimeout = const Duration(milliseconds: 600);
    final library = LibraryService();
    await library.init();
    final silent = (await library.addLocalFiles([
      File(p.join(sandbox.path, 'silent2.mp4'))..writeAsBytesSync(List.filled(4096, 3)),
    ])).single;
    final fine = (await library.addLocalFiles([
      File(p.join(sandbox.path, 'fine2.mp3'))..writeAsBytesSync(List.filled(4096, 4)),
    ])).single;

    final player = PlayerService(library);
    final stuck = player.playSong(silent);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    calls.clear();
    await player.playSong(fine).timeout(const Duration(seconds: 5));
    await stuck.timeout(const Duration(seconds: 5));
    // Past the stuck song's timeout: it must not reset or blame the new one.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(player.currentSong?.id, fine.id);
    expect(player.playbackError, isNull);
    expect(calls, containsAllInOrder(['load', 'play']));
    expect(calls.where((c) => c == 'load'), hasLength(1),
        reason: 'the stuck timeout must not reload or stop the new song');
});
}
