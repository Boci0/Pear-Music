import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/debug_log.dart';
import 'package:peerm_app/services/innertube_audio_engine.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

/// Songs played on a slow, unstable connection and skipped before their end
/// must play from the cache later, without waiting on the network, even when
/// the connection is up but delivers nothing. The fast engine runs for real;
/// only its YouTube answers and byte stream are simulated here.
const _songBytes = 400 * 1024;

Map<String, dynamic> _playerOk(String videoId, [int bytes = _songBytes]) => {
      'playabilityStatus': {'status': 'OK'},
      'responseContext': {'visitorData': 'slow-net-visitor'},
      'streamingData': {
        'adaptiveFormats': [
          {
            'itag': 251,
            'mimeType': 'audio/webm; codecs="opus"',
            'averageBitrate': 128000,
            'contentLength': '$bytes',
            'url': 'https://slow.invalid/$videoId',
          },
        ],
      },
    };

/// About 400 KB/s in small pieces, with one long pause in the middle.
Stream<List<int>> _slowAndUnstable(int bytes) async* {
  const piece = 16 * 1024;
  var sent = 0;
  var n = 0;
  while (sent < bytes) {
    await Future<void>.delayed(
      Duration(milliseconds: ++n == 12 ? 600 : 40),
    );
    final size = bytes - sent < piece ? bytes - sent : piece;
    yield List.filled(size, 7);
    sent += size;
  }
}

/// Connects, then never delivers a byte.
Stream<List<int>> _stuck() => Completer<List<int>>().future.asStream();

Song _song(String videoId) => Song(
      id: 'stream_$videoId',
      title: 'Song $videoId',
      fileName: 'stream_$videoId.webm',
      size: 0,
      checksum: 'stream_$videoId',
      sourceDeviceId: 'stream',
      addedAt: DateTime(2026, 11, 23),
    );

/// Takes any source and reports playing; never reads or finishes a song.
class _Engine extends AudioPlayer {
  _Engine() : super(handleAudioSessionActivation: false);
  bool _playing = false;

  @override
  bool get playing => _playing;

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async => const Duration(minutes: 3);

  @override
  Future<void> play() async => _playing = true;

  @override
  Future<void> pause() async => _playing = false;

  @override
  Future<void> stop() async => _playing = false;

  @override
  Future<void> seek(Duration? position, {int? index}) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setLoopMode(LoopMode mode) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sandbox = Directory.systemTemp.createTempSync('peerm_slow_net_');

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => sandbox.path);
  });

  tearDownAll(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  tearDown(() async {
    StreamCacheManager.cancelPreload();
    StreamCacheManager.cancelActiveDownload();
    StreamCacheManager.debugAllowFastEngineInTests = false;
    StreamCacheManager.debugSkipFallbackEngines = false;
    InnerTubeAudioEngine.debugReset();
    await StreamCacheManager.clearCache();
  });

  test('a song skipped on a slow link plays from the cache when the link '
      'later stalls', () async {
    StreamCacheManager.debugAllowFastEngineInTests = true;
    StreamCacheManager.debugSkipFallbackEngines = true;
    StreamCacheManager.clearRamCacheForTesting();
    InnerTubeAudioEngine.debugReset();
    InnerTubeAudioEngine.debugPlayerOverride =
        (videoId, _) async => _playerOk(videoId);
    final opened = <String>[];
    var network = _slowAndUnstable;
    InnerTubeAudioEngine.debugOpenOverride = (url, bytes) {
      opened.add(url.split('/').last);
      return network(bytes);
    };

    final ids = [for (var i = 0; i < 6; i++) 'slowsong00$i'];
    final queue = ids.map(_song).toList();
    final player = PlayerService(LibraryService(), player: _Engine());
    await player.setLoudnessNormalization(false);

    Future<void> fetched(String id) async {
      for (var i = 0; i < 100; i++) {
        if (StreamCacheManager.isStreamCachedSync(id)) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('$id never finished downloading:\n'
          '${DebugLog.recentLogs.join('\n')}');
    }

    // Each song starts on the slow link and is skipped before it ends; five
    // more songs push the first one out of the four-song RAM cache.
    await player.playSong(queue[0], queue: queue);
    await fetched(ids[0]);
    for (var i = 1; i < ids.length; i++) {
      await player.next(userAction: true);
      await fetched(ids[i]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // The connection is now up but stuck.
    network = (_) => _stuck();
    opened.clear();
    final clock = Stopwatch()..start();
    unawaited(player.playSong(queue[0], queue: queue));
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    expect(player.currentSong?.id, queue[0].id);
    expect(player.isBuffering, isFalse,
        reason: 'a song heard before must not wait on the network');
    expect(player.currentRouteType, StreamRouteType.cached);
    expect(opened.where((id) => id == ids[0]), isEmpty,
        reason: 'the cached song is not downloaded again');
    expect(player.lastTrackLoadMs, inInclusiveRange(0, 500));
    // ignore: avoid_print
    print('replay on a stuck link: loaded from cache in '
        '${player.lastTrackLoadMs} ms (checked after ${clock.elapsedMilliseconds} ms)');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a new song starts after half a megabyte, a long mix before its '
      'download ends', () async {
    StreamCacheManager.debugAllowFastEngineInTests = true;
    StreamCacheManager.debugSkipFallbackEngines = true;
    StreamCacheManager.clearRamCacheForTesting();
    InnerTubeAudioEngine.debugReset();
    const songBytes = 3 * 1024 * 1024;
    const mixBytes = 30 * 1024 * 1024;
    InnerTubeAudioEngine.debugPlayerOverride = (videoId, _) async =>
        _playerOk(videoId, videoId.startsWith('longmix') ? mixBytes : songBytes);
    final hold = Completer<void>();
    // About 640 KB/s; the long mix then stalls until the test lets it go.
    InnerTubeAudioEngine.debugOpenOverride = (url, bytes) async* {
      const piece = 16 * 1024;
      var sent = 0;
      while (sent < bytes) {
        if (url.contains('longmix') && sent >= 1024 * 1024) await hold.future;
        await Future<void>.delayed(const Duration(milliseconds: 25));
        final size = bytes - sent < piece ? bytes - sent : piece;
        yield List.filled(size, 5);
        sent += size;
      }
    };
    final player = PlayerService(LibraryService(), player: _Engine());
    await player.setLoudnessNormalization(false);

    final song = _song('newsong0001');
    await player.playSong(song, queue: [song]);
    expect(player.currentRouteType, StreamRouteType.direct);
    expect(player.lastTrackLoadMs, lessThan(2000),
        reason: 'two megabytes take over 3 s on this link');

    final mix = _song('longmix0001');
    await player.playSong(mix, queue: [mix]);
    expect(player.currentSong?.id, mix.id);
    expect(player.playbackError, isNull);
    expect(player.currentRouteType, StreamRouteType.direct,
        reason: 'playing from the file being written, not after all 30 MB');
    hold.complete();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
