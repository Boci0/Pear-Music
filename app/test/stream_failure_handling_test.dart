import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
      addedAt: DateTime(2026, 9, 21),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Sandbox path_provider into a throwaway directory so tests never write
  // into the real peerm_radio_cache used by the running app.
  final sandbox = Directory.systemTemp.createTempSync('peerm_stream_failure_');
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

  group('stream fetch failure classification', () {
    test('HTTP 403 and bot checks count as retryable blocks', () {
      expect(
        StreamCacheManager.classifyFetchFailure(
            'ERROR: unable to download video data: HTTP Error 403: Forbidden'),
        StreamFetchFailureKind.blocked,
      );
      expect(
        StreamCacheManager.classifyFetchFailure(
            "Sign in to confirm you're not a bot"),
        StreamFetchFailureKind.blocked,
      );
    });

    test('deleted and private videos count as unavailable, not blocked', () {
      expect(
        StreamCacheManager.classifyFetchFailure('ERROR: Video unavailable'),
        StreamFetchFailureKind.unavailable,
      );
      expect(
        StreamCacheManager.classifyFetchFailure(
            "Private video. Sign in if you've been granted access"),
        StreamFetchFailureKind.unavailable,
      );
    });

    test('other permanently unreachable videos also count as unavailable', () {
      expect(
        StreamCacheManager.classifyFetchFailure(
            'ERROR: The uploader has not made this video available in your country'),
        StreamFetchFailureKind.unavailable,
      );
      expect(
        StreamCacheManager.classifyFetchFailure(
            'ERROR: Sign in to confirm your age. This video may be inappropriate for some users.'),
        StreamFetchFailureKind.unavailable,
      );
    });

    test('timeouts and connection errors count as network failures', () {
      expect(
        StreamCacheManager.classifyFetchFailure(
            'download timed out after 120s'),
        StreamFetchFailureKind.network,
      );
      expect(
        StreamCacheManager.classifyFetchFailure(
            'ERROR: unable to download video data: Connection reset by peer'),
        StreamFetchFailureKind.network,
      );
    });

    test('a missing yt-dlp counts as an engine failure', () {
      expect(
        StreamCacheManager.classifyFetchFailure(
            'yt-dlp is missing on this device'),
        StreamFetchFailureKind.engine,
      );
    });

    test('recorded failures are consumed once', () {
      StreamCacheManager.recordFetchFailure(
          'vid_release_once', 'HTTP Error 403: Forbidden');

      final failure = StreamCacheManager.takeFetchFailure('vid_release_once');
      expect(failure?.kind, StreamFetchFailureKind.blocked);
      expect(StreamCacheManager.takeFetchFailure('vid_release_once'), isNull);
    });
  });

  group('describeStreamFailure', () {
    test('a 403 is framed as temporary and offers a retry', () {
      final described = PlayerService.describeStreamFailure(
        const StreamFetchFailure(
          videoId: 'dQw4w9WgXcQ',
          kind: StreamFetchFailureKind.blocked,
          detail: 'HTTP Error 403',
        ),
        _streamSong('dQw4w9WgXcQ', 'Blocked Song'),
      );

      expect(described.kind, StreamFetchFailureKind.blocked);
      expect(described.label.toLowerCase(), contains('retry'));
      expect(described.message, contains('Blocked Song'));
    });

    test('an unavailable video says it was skipped', () {
      final described = PlayerService.describeStreamFailure(
        const StreamFetchFailure(
          videoId: 'gonetrack00',
          kind: StreamFetchFailureKind.unavailable,
          detail: 'Video unavailable',
        ),
        _streamSong('gonetrack00', 'Gone Song'),
      );

      expect(described.message.toLowerCase(), contains('skipped'));
    });
  });

  group('preload failures', () {
    test('a blocked preload retries once so the next track does not start cold',
        () async {
      final calls = <String>[];
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async {
        calls.add(videoId);
        if (calls.length == 1) {
          StreamCacheManager.recordFetchFailure(
              videoId, 'ERROR: unable to download video data: HTTP Error 403: Forbidden');
          return null;
        }
        final file = File('${sandbox.path}${Platform.pathSeparator}$videoId.m4a');
        await file.writeAsBytes(List.filled(64, 0));
        return file;
      };

      final cached = <String>[];
      final done = Completer<void>();
      StreamCacheManager.preloadSlidingWindow(
        ['preloadBlk1'],
        onTrackCached: cached.add,
        onDone: done.complete,
      );
      await done.future.timeout(const Duration(seconds: 5));

      expect(calls, ['preloadBlk1', 'preloadBlk1']);
      expect(cached, ['preloadBlk1']);
    });

    test('a preload that can never play is not retried', () async {
      final calls = <String>[];
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async {
        calls.add(videoId);
        StreamCacheManager.recordFetchFailure(videoId, 'ERROR: Video unavailable');
        return null;
      };

      final done = Completer<void>();
      StreamCacheManager.preloadSlidingWindow(['preloadGone'], onDone: done.complete);
      await done.future.timeout(const Duration(seconds: 5));

      expect(calls, ['preloadGone']);
    });
  });

  group('playSong stream failures', () {
    late PlayerService player;

    setUp(() {
      player = PlayerService(LibraryService());
    });

    tearDown(() {
      player.dispose();
    });

    test('a blocked stream stays on its track with an error instead of skipping',
        () async {
      final first = _streamSong('dQw4w9WgXcQ', 'First Song');
      final second = _streamSong('abcdefghijk', 'Second Song');
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async {
        StreamCacheManager.recordFetchFailure(
            videoId, 'ERROR: unable to download video data: HTTP Error 403: Forbidden');
        return null;
      };

      final messages = <String>[];
      final sub = player.userMessages.listen(messages.add);

      await player.playSong(first, queue: [first, second]);

      expect(player.currentSong?.id, first.id,
          reason: 'a blocked track must not be skipped past');
      expect(player.queueIndex, 0);
      expect(player.playbackError, isNotNull);
      expect(player.playbackError!.kind, StreamFetchFailureKind.blocked);
      expect(messages, isNotEmpty,
          reason: 'the user must be told why the track stopped');
      expect(messages.last, contains('First Song'));

      await sub.cancel();
    });

    test('tapping play retries the failed track instead of moving on', () async {
      final first = _streamSong('dQw4w9WgXcQ', 'First Song');
      final second = _streamSong('abcdefghijk', 'Second Song');
      var attempts = 0;
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async {
        attempts++;
        StreamCacheManager.recordFetchFailure(
            videoId, 'ERROR: unable to download video data: HTTP Error 403: Forbidden');
        return null;
      };

      await player.playSong(first, queue: [first, second]);
      final attemptsAfterFirstPlay = attempts;
      expect(attemptsAfterFirstPlay, greaterThanOrEqualTo(2),
          reason: 'the initial fetch plus one quick retry');
      expect(player.playbackError, isNotNull);

      await player.resume();

      expect(attempts, greaterThan(attemptsAfterFirstPlay),
          reason: 'resume on a failed track must run a fresh fetch');
      expect(player.currentSong?.id, first.id);
      expect(player.playbackError, isNotNull);
    });

    test('an unavailable video is skipped so the queue keeps moving', () async {
      final first = _streamSong('dQw4w9WgXcQ', 'First Song');
      final second = _streamSong('abcdefghijk', 'Second Song');
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async {
        // The dead track is skipped; the next one is blocked, which must stop
        // on it with an error instead of cascading further.
        StreamCacheManager.recordFetchFailure(
          videoId,
          videoId == 'dQw4w9WgXcQ'
              ? 'ERROR: Video unavailable'
              : 'ERROR: unable to download video data: HTTP Error 403: Forbidden',
        );
        return null;
      };

      final messages = <String>[];
      final sub = player.userMessages.listen(messages.add);

      await player.playSong(first, queue: [first, second]);
      // Let the auto-skip chain settle (the blocked track retries once).
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(player.currentSong?.id, second.id,
          reason: 'a video that can never play must not stall the queue');
      expect(messages.join(' ').toLowerCase(), contains('skipped'));
      expect(player.playbackError?.kind, StreamFetchFailureKind.blocked,
          reason: 'the blocked track after the skip must stop with an error');

      await sub.cancel();
    });
  });
}
