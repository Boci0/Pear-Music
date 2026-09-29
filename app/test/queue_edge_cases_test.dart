import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

Song _streamSong(String videoId) => Song(
      id: 'stream_$videoId',
      title: 'Song $videoId',
      fileName: 'stream_$videoId.m4a',
      size: 0,
      checksum: 'stream_$videoId',
      sourceDeviceId: 'stream',
      addedAt: DateTime(2026, 9, 29),
    );

/// A silent engine that only records which files were loaded.
class _FakePlayer extends AudioPlayer {
  _FakePlayer() : super(handleAudioSessionActivation: false);

  final List<String> loaded = [];
  bool _playing = false;
  double _volume = 1.0;

  @override
  bool get playing => _playing;

  @override
  double get volume => _volume;

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => const Duration(minutes: 1);

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    loaded.add(p.basenameWithoutExtension(
        (source as UriAudioSource).uri.toFilePath()));
    return const Duration(minutes: 1);
  }

  @override
  Future<void> setVolume(double volume) async => _volume = volume;

  @override
  Future<void> seek(Duration? position, {int? index}) async {}

  @override
  Future<void> play() async => _playing = true;

  @override
  Future<void> pause() async => _playing = false;

  @override
  Future<void> stop() async => _playing = false;

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setLoopMode(LoopMode mode) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ids = ['aaaaaaaaaaa', 'bbbbbbbbbbb', 'ccccccccccc', 'ddddddddddd'];
  final sandbox = Directory.systemTemp.createTempSync('peerm_queue_edges_');
  setUpAll(() async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => sandbox.path);
    final cache = await StreamCacheManager.getCacheDirectory();
    for (final id in ids) {
      File(p.join(cache.path, '$id.m4a'))
          .writeAsBytesSync(List.filled(60000, 1));
      await StreamCacheManager.getCachedFile(id);
    }
  });
  tearDownAll(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<(_FakePlayer, PlayerService)> start(List<Song> queue, Song first) async {
    final engine = _FakePlayer();
    final player = PlayerService(LibraryService(), player: engine);
    await player.setLoudnessNormalization(false);
    await player.playSong(first, queue: queue);
    return (engine, player);
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  test('removing the current song and one before it plays the song that '
      'followed the current one', () async {
    final songs = ids.map(_streamSong).toList();
    final (engine, player) = await start(songs, songs[2]);

    player.removeSongsFromQueue({songs[0].id, songs[2].id});
    await settle();

    expect(player.currentSong?.id, songs[3].id,
        reason: 'D came after C, so it is what plays next (not B)');
    expect(player.queue.map((s) => s.id), [songs[1].id, songs[3].id]);
    expect(player.queueIndex, 1);
    expect(engine.loaded.last, ids[3]);
  });

  test('removing the last song of the queue wraps to the first', () async {
    final songs = ids.map(_streamSong).toList();
    final (_, player) = await start(songs, songs[3]);

    player.removeSongsFromQueue({songs[3].id});
    await settle();

    expect(player.currentSong?.id, songs[0].id);
    expect(player.queueIndex, 0);
  });

  test('shuffle on a one-song queue stops at the end unless looping all',
      () async {
    final only = _streamSong(ids[0]);
    final (engine, player) = await start([only], only);
    player.toggleShuffle();

    await player.next();
    await settle();
    expect(engine.loaded, [ids[0]],
        reason: 'loop off: the song is not started again');
    expect(engine.playing, isFalse);

    await player.toggleLoop(); // all
    await player.next();
    await settle();
    expect(engine.loaded, [ids[0], ids[0]],
        reason: 'loop all: the only song plays again');
  });

  test('stop() during a load leaves the player ready to play again', () async {
    final songs = ids.map(_streamSong).toList();
    final (_, player) = await start(songs, songs[0]);

    player.setBufferingForTesting(true);
    await player.stop();

    expect(player.isLoadingTrack, isFalse);
    expect(player.isBuffering, isFalse);
    expect(player.isAdvancing, isFalse);
    expect(player.currentSong, isNull);
  });
}
