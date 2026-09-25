import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

Song _streamSong(String videoId, String title) => Song(
      id: 'stream_$videoId',
      title: title,
      fileName: 'stream_$videoId.m4a',
      size: 0,
      checksum: 'stream_$videoId',
      sourceDeviceId: 'stream',
      addedAt: DateTime(2026, 9, 25),
    );

/// Records what playback is asked to load instead of touching a real audio
/// engine. [failUris] makes direct links fail to load, like a link the
/// engine cannot open.
class _RecordingAudioPlayer extends AudioPlayer {
  _RecordingAudioPlayer({this.failUris = false});

  final bool failUris;
  final List<AudioSource> loaded = [];

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    loaded.add(source);
    if (failUris && source is UriAudioSource && source.uri.scheme != 'file') {
      throw PlayerException(0, 'cannot open link', null);
    }
    return const Duration(minutes: 3);
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setLoopMode(LoopMode mode) async {}
}

const _link = ResolvedStream(
  url: 'https://rr1---sn-test.googlevideo.com/videoplayback?id=1',
  headers: {'User-Agent': 'Mozilla/5.0 test'},
  ext: 'webm',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Directory.systemTemp.createTempSync('peerm_stream_caching_');
  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return sandbox.path;
    });
  });

  tearDownAll(() {
    try {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  tearDown(() {
    StreamCacheManager.debugEnsureStreamCachedOverride = null;
    StreamCacheManager.cancelActiveDownload();
    StreamCacheManager.cancelPreload();
  });

  group('parseStreamLine', () {
    test('reads the link, headers and format from the printed line', () {
      final stream = StreamCacheManager.parseStreamLine(
        'PEARSTREAM {"url": "https://a.googlevideo.com/x?y=1", '
        '"http_headers": {"User-Agent": "UA", "Accept": "*/*"}, "ext": "webm"}',
      );
      expect(stream, isNotNull);
      expect(stream!.url, 'https://a.googlevideo.com/x?y=1');
      expect(stream.headers, {'User-Agent': 'UA', 'Accept': '*/*'});
      expect(stream.ext, 'webm');
    });

    test('ignores other output and malformed lines', () {
      expect(StreamCacheManager.parseStreamLine('[download] 10%'), isNull);
      expect(StreamCacheManager.parseStreamLine('PEARSTREAM not json'), isNull);
      expect(
        StreamCacheManager.parseStreamLine('PEARSTREAM {"url": "NA"}'),
        isNull,
        reason: 'a missing url prints as NA and must not be played',
      );
    });
  });

  group('Android plugin links', () {
    test('a streamResolved call from the plugin reaches the waiting caller',
        () async {
      final received = <ResolvedStream>[];
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async {
        // What the embedded download path does, then the plugin reporting
        // the printed line over the method channel.
        StreamCacheManager.debugTrackAndroidFetch('peerm-fast-1', videoId);
        await StreamCacheManager.handleAndroidPluginCall(
          const MethodCall('streamResolved', {
            'processId': 'peerm-fast-1',
            'line': 'PEARSTREAM {"url": "https://a.googlevideo.com/p?x=1", '
                '"http_headers": {"User-Agent": "UA"}, "ext": "m4a"}',
          }),
        );
        return null;
      };

      await StreamCacheManager.ensureStreamCached(
        'androidVid1',
        onStreamUrl: received.add,
      );

      expect(received, hasLength(1));
      expect(received.single.url, 'https://a.googlevideo.com/p?x=1');
      expect(received.single.ext, 'm4a');
    });

    test('links for an unknown process are ignored', () async {
      final received = <ResolvedStream>[];
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async {
        await StreamCacheManager.handleAndroidPluginCall(
          const MethodCall('streamResolved', {
            'processId': 'someone-else',
            'line': 'PEARSTREAM {"url": "https://a.googlevideo.com/p"}',
          }),
        );
        return null;
      };

      await StreamCacheManager.ensureStreamCached(
        'androidVid2',
        onStreamUrl: received.add,
      );

      expect(received, isEmpty);
    });
  });

  group('play while caching', () {
    test('playback starts from the direct link before the download ends',
        () async {
      final audio = _RecordingAudioPlayer();
      final player = PlayerService(LibraryService(), player: audio);
      final song = _streamSong('dQw4w9WgXcQ', 'Long Mix');
      final downloadDone = Completer<File?>();
      var downloadFinished = false;
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async {
        StreamCacheManager.debugPublishResolvedStream(videoId, _link);
        final file = await downloadDone.future;
        downloadFinished = true;
        return file;
      };

      await player.playSong(song, queue: [song]);

      expect(downloadFinished, isFalse,
          reason: 'playback must not wait for the whole file');
      expect(audio.loaded, hasLength(1));
      final source = audio.loaded.single as UriAudioSource;
      expect(source.uri.toString(), _link.url);
      expect(source.headers, _link.headers);
      expect(player.playbackError, isNull);

      downloadDone.complete(null);
      await Future<void>.delayed(Duration.zero);
    });

    test('a link that will not play falls back to the cached file', () async {
      final audio = _RecordingAudioPlayer(failUris: true);
      final player = PlayerService(LibraryService(), player: audio);
      final song = _streamSong('abcdefghijk', 'Short Song');
      final cached = File(p.join(sandbox.path, 'abcdefghijk.webm'))
        ..writeAsBytesSync(List.filled(64, 1));
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async {
        StreamCacheManager.debugPublishResolvedStream(videoId, _link);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return cached;
      };

      await player.playSong(song, queue: [song]);

      expect(audio.loaded, hasLength(2));
      // Compare as paths, not strings, so the check holds with Windows
      // separators too.
      expect(
        p.equals(
          (audio.loaded.last as UriAudioSource).uri.toFilePath(),
          cached.path,
        ),
        isTrue,
      );
      expect(player.playbackError, isNull);
    });
  });
}
