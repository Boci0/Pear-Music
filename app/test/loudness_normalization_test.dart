import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
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
      addedAt: DateTime(2026, 9, 26),
    );

/// Remembers every volume playback asks for instead of touching an engine.
class _VolumePlayer extends AudioPlayer {
  double _volume = 1.0;
  final List<double> volumes = [];

  @override
  double get volume => _volume;

  @override
  bool get playing => true;

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    volumes.add(volume);
  }

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async =>
      const Duration(minutes: 3);

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setLoopMode(LoopMode mode) async {}
}

double _db(double gain) => 20 * math.log(gain) / math.ln10;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Directory.systemTemp.createTempSync('peerm_loudness_');
  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => sandbox.path);
  });
  tearDownAll(() => sandbox.deleteSync(recursive: true));
  setUp(LoudnessService.resetForTesting);
  tearDown(() => StreamCacheManager.debugEnsureStreamCachedOverride = null);

  group('gain', () {
    test('an unmeasured song plays unchanged', () {
      expect(LoudnessService.gainForLufs(null), 1.0);
    });

    test('a loud master is turned down to the target', () {
      expect(_db(LoudnessService.gainForLufs(-8)), closeTo(-6, 0.01));
    });

    test('a quiet song is lifted, but by no more than the cap', () {
      expect(_db(LoudnessService.gainForLufs(-17)), closeTo(3, 0.01));
      expect(
        _db(LoudnessService.gainForLufs(-40)),
        closeTo(LoudnessService.maxBoostDb, 0.01),
      );
    });

    test('a stream and its library copy share one measurement', () {
      final stream = _streamSong('dQw4w9WgXcQ');
      final saved = Song(
        id: 'b2c9e2f0-0000-4000-8000-000000000000',
        title: 'Saved copy',
        fileName: 'Saved copy [dQw4w9WgXcQ].m4a',
        size: 1,
        checksum: 'x',
        addedAt: DateTime(2026, 9, 26),
      );
      expect(LoudnessService.keyFor(saved), LoudnessService.keyFor(stream));
    });
  });

  group('playback', () {
    Future<(_VolumePlayer, PlayerService)> playMeasured({
      required bool normalize,
    }) async {
      final file = File('${sandbox.path}/cached.m4a')..writeAsBytesSync([0]);
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async => file;
      final audio = _VolumePlayer();
      final player = PlayerService(LibraryService(), player: audio);
      await player.setLoudnessNormalization(normalize);
      await player.setVolume(0.8);
      final song = _streamSong('aaaaaaaaaaa');
      LoudnessService.setForTesting('aaaaaaaaaaa', -8);
      await player.playSong(song, queue: [song]);
      // Let the short fade-in finish.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return (audio, player);
    }

    test('a measured song fades in at its levelled volume', () async {
      final (audio, _) = await playMeasured(normalize: true);
      expect(audio.volume, closeTo(0.8 * LoudnessService.gainForLufs(-8), 0.001));
    });

    test('with normalisation off the song plays at the user volume', () async {
      final (audio, _) = await playMeasured(normalize: false);
      expect(audio.volume, closeTo(0.8, 0.001));
    });

    test('the volume slider still means the same thing on a levelled song',
        () async {
      final (audio, player) = await playMeasured(normalize: true);
      await player.setVolume(0.5);
      expect(player.volume, 0.5);
      expect(audio.volume, closeTo(0.5 * LoudnessService.gainForLufs(-8), 0.001));
    });
  });
}
