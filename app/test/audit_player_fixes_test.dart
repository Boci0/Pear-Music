import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/loudness_meter.dart';
import 'package:peerm_app/services/loudness_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

Song _streamSong(String videoId) => Song(
      id: 'stream_$videoId',
      title: 'Song $videoId',
      fileName: 'stream_$videoId.m4a',
      size: 0,
      checksum: 'stream_$videoId',
      sourceDeviceId: 'stream',
      addedAt: DateTime(2026, 10, 20),
    );

const _ids = ['aaaaaaaaaaa', 'bbbbbbbbbbb', 'ccccccccccc', 'ddddddddddd'];

/// A silent engine for the player core fixes: records what was loaded and
/// lets a test hold a source load open, fail it, or make volume changes throw.
class _FakePlayer extends AudioPlayer {
  _FakePlayer() : super(handleAudioSessionActivation: false);

  final List<String> loaded = [];
  Duration position_ = Duration.zero;
  Duration? duration_ = const Duration(minutes: 1);
  ProcessingState processingState_ = ProcessingState.ready;

  /// When set, the next source load waits on this completer.
  Completer<Duration?>? sourceGate;

  /// When set, the next source load throws this error.
  Object? nextSourceError;

  /// When true, volume changes throw, like a platform error in a fade.
  bool failsVolume = false;
  int stops = 0;

  double _volume = 1.0;
  bool _playing = false;

  @override
  bool get playing => _playing;

  @override
  double get volume => _volume;

  @override
  Duration? get duration => duration_;

  @override
  ProcessingState get processingState => processingState_;

  @override
  Duration get position => position_;

  @override
  Duration get bufferedPosition => position_;

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    final uri = (source as UriAudioSource).uri;
    loaded.add(
      uri.scheme == 'file' ? p.basename(uri.toFilePath()) : uri.toString(),
    );
    final error = nextSourceError;
    if (error != null) {
      nextSourceError = null;
      throw error;
    }
    final gate = sourceGate;
    if (gate != null) {
      sourceGate = null;
      await gate.future;
    }
    if (initialPosition != null) position_ = initialPosition;
    return duration_;
  }

  @override
  Future<void> setVolume(double volume) async {
    if (failsVolume) throw StateError('volume failed');
    _volume = volume;
  }

  @override
  Future<void> play() async => _playing = true;

  @override
  Future<void> pause() async => _playing = false;

  @override
  Future<void> stop() async {
    _playing = false;
    stops++;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (position != null) position_ = position;
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setLoopMode(LoopMode mode) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Directory.systemTemp.createTempSync('peerm_audit_fixes_');

  setUpAll(() async {
    StreamCacheManager.debugEnsureStreamCachedOverride =
        (videoId, {required isPreload}) async => null;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => sandbox.path);
    final cache = await StreamCacheManager.getCacheDirectory();
    for (final id in _ids) {
      File(p.join(cache.path, '$id.m4a')).writeAsBytesSync(List.filled(60000, 1));
      await StreamCacheManager.getCachedFile(id);
    }
  });

  tearDownAll(() {
    StreamCacheManager.debugEnsureStreamCachedOverride = null;
    LoudnessService.debugSupportedOverride = null;
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    LoudnessService.resetForTesting();
    // Keep the loudness pass out of the tests; the silent-outro test seeds its
    // own span through the test seam.
    LoudnessService.debugSupportedOverride = false;
  });

  tearDown(() {
    StreamCacheManager.cancelActiveDownload();
    StreamCacheManager.cancelPreload();
  });

  Future<void> settle([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> untilSong(PlayerService player, String id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline) && player.currentSong?.id != id) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await settle(60);
  }

  Future<(PlayerService, _FakePlayer, List<Song>)> start(
    List<String> ids, {
    Song? first,
    bool shuffle = false,
  }) async {
    final songs = ids.map(_streamSong).toList();
    final engine = _FakePlayer();
    final player = PlayerService(LibraryService(), player: engine);
    addTearDown(player.dispose);
    await player.setLoudnessNormalization(false);
    if (shuffle) player.toggleShuffle();
    await player.playSong(first ?? songs.first, queue: songs);
    await settle(150);
    return (player, engine, songs);
  }

  test('PC-01: replaying a queue restarts shuffle instead of treating its '
      'songs as already played', () async {
    final (player, engine, songs) = await start(_ids, shuffle: true);
    // Play through the queue so every song id is in the shuffle played set.
    for (var i = 0; i < songs.length; i++) {
      await player.next();
      await settle(30);
    }

    // The listener picks the same queue again (a new list instance).
    await player.playSong(songs.first, queue: List<Song>.of(songs));
    await settle(120);
    final loadedBefore = engine.loaded.length;

    await player.next();
    await settle(150);

    expect(engine.loaded.length, greaterThan(loadedBefore),
        reason: 'shuffle still has unplayed songs in the new queue');
    expect(player.currentSong?.id, isNot(songs.first.id));
    expect(player.isAdvancing, isFalse);
  });

  test('PC-02: a superseded cached load keeps its cache file and does not '
      'report a playback failure', () async {
    final cache = await StreamCacheManager.getCacheDirectory();
    final cached = File(p.join(cache.path, 'aaaaaaaaaaa.m4a'));
    final engine = _FakePlayer();
    final player = PlayerService(LibraryService(), player: engine);
    addTearDown(player.dispose);
    await player.setLoudnessNormalization(false);
    final songs = _ids.map(_streamSong).toList();

    engine.nextSourceError =
        PlayerInterruptedException('Loading interrupted');
    await player.playSong(songs.first, queue: songs);
    await settle(120);

    expect(player.playbackError, isNull,
        reason: 'an interrupted load is superseded, not a failure');
    expect(player.isLoadingTrack, isFalse);
    expect(player.isAdvancing, isFalse);
    expect(cached.existsSync(), isTrue,
        reason: 'the cached file is valid and must not be evicted');
    expect(StreamCacheManager.isStreamCachedSync('aaaaaaaaaaa'), isTrue);
  });

  test('PC-03: pausing during a skip fade keeps the current track and the '
      'paused state', () async {
    final (player, engine, songs) = await start(_ids);

    final advance = player.next();
    // The skip is now fading out; the listener pauses.
    await player.pause();
    await advance;
    await settle(120);

    expect(player.currentSong?.id, songs.first.id,
        reason: 'the pause wins over the in-flight skip');
    expect(engine.playing, isFalse);
    expect(engine.loaded, hasLength(1));
    expect(player.isAdvancing, isFalse);
  });

  test('PC-03: pausing during a previous fade keeps the current track',
      () async {
    final (player, engine, songs) = await start(_ids);
    engine.position_ = const Duration(seconds: 1);

    final back = player.previous();
    await player.pause();
    await back;
    await settle(120);

    expect(player.currentSong?.id, songs.first.id);
    expect(engine.loaded, hasLength(1));
    expect(player.isAdvancing, isFalse);
  });

  test('PC-05: a failed volume fade during a skip does not leave the player '
      'advancing', () async {
    final (player, engine, songs) = await start(_ids);

    engine.failsVolume = true;
    await player.next();
    await settle(60);

    expect(player.currentSong?.id, songs.first.id,
        reason: 'the skip could not fade, so it did not advance');
    expect(player.isAdvancing, isFalse,
        reason: 'the guard flag is cleared even when the fade throws');

    engine.failsVolume = false;
    await player.next();
    await settle(120);
    expect(player.currentSong?.id, songs[1].id,
        reason: 'next still works after the failed fade');
  });

  test('PC-04: starting radio during a load for the same song clears the '
      'abandoned load flags', () async {
    final engine = _FakePlayer();
    final player = PlayerService(LibraryService(), player: engine);
    addTearDown(player.dispose);
    await player.setLoudnessNormalization(false);
    final songs = _ids.map(_streamSong).toList();

    final gate = Completer<Duration?>();
    engine.sourceGate = gate;
    final load = player.playSong(songs.first, queue: songs);
    final loadDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(loadDeadline) && engine.loaded.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(engine.loaded, isNotEmpty, reason: 'the seed load is in flight');
    expect(player.isLoadingTrack, isTrue);

    await player.startRadio(songs.first);
    await settle(30);

    expect(player.queueSourceId, 'radio');
    expect(player.isLoadingTrack, isFalse,
        reason: 'the abandoned load must not leave the player buffering');
    expect(player.isBuffering, isFalse);
    expect(player.isAdvancing, isFalse);

    gate.complete(null);
    await load.timeout(const Duration(seconds: 2));
    await settle(30);
  });

  test('PC-07: seeking to the end while paused stays paused on the same '
      'track; playing still moves on', () async {
    final (player, engine, songs) = await start(_ids);
    await player.pause();
    await player.seek(const Duration(minutes: 1));
    await settle(120);

    expect(player.currentSong?.id, songs.first.id);
    expect(engine.playing, isFalse);
    expect(engine.loaded, hasLength(1));

    await player.resume();
    await settle(120);
    await player.seek(const Duration(minutes: 1));
    await untilSong(player, songs[1].id);
    expect(player.currentSong?.id, songs[1].id);
  });

  test('PC-13: the queue getter returns a cached view that follows queue '
      'changes', () async {
    final (player, _, songs) = await start(_ids);

    final view = player.queue;
    expect(identical(view, player.queue), isTrue,
        reason: 'reading the queue must not copy it again');
    expect(view.map((s) => s.id).toList(), songs.map((s) => s.id).toList());

    player.removeFromQueue(1);
    await settle(60);

    expect(identical(view, player.queue), isFalse,
        reason: 'a queue change gives a new view');
    expect(player.queue.map((s) => s.id).toList(),
        [songs[0].id, songs[2].id, songs[3].id]);
  });

  test('PC-14: a silent outro whose span arrives after playback started is '
      'still skipped', () async {
    final (player, engine, songs) = await start(_ids);
    expect(engine.playing, isTrue);

    // No span yet: the first tick past the music end does nothing.
    engine.position_ = const Duration(seconds: 55, milliseconds: 500);
    player.debugCrossfadeTick(engine.position_);
    await settle(100);
    expect(player.currentSong?.id, songs.first.id);

    // The loudness pass finishes mid song and the span becomes known.
    LoudnessService.setSpanForTesting(
      'aaaaaaaaaaa',
      const LoudnessAnalysis(
        lufs: -14,
        musicStart: 0,
        musicEnd: 55,
        length: 60,
      ),
    );
    engine.position_ = const Duration(seconds: 55, milliseconds: 100);
    player.debugCrossfadeTick(engine.position_);
    await untilSong(player, songs[1].id);

    expect(player.currentSong?.id, songs[1].id,
        reason: 'the newly known silent outro ends the song early');
  });
}
