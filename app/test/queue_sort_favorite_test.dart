import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/pear_audio_handler.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/recommendation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return Directory.systemTemp.path;
    });
  });

  group('PlayerService queue updates and context isolation', () {
    final songA = Song(
      id: 'a',
      title: 'Alpha',
      fileName: 'a.mp3',
      size: 100,
      checksum: 'chk_a',
      addedAt: DateTime(2026, 1, 1),
    );
    final songB = Song(
      id: 'b',
      title: 'Beta',
      fileName: 'b.mp3',
      size: 200,
      checksum: 'chk_b',
      addedAt: DateTime(2026, 1, 2),
    );
    final songC = Song(
      id: 'c',
      title: 'Gamma',
      fileName: 'c.mp3',
      size: 300,
      checksum: 'chk_c',
      addedAt: DateTime(2026, 1, 3),
    );
    final songD = Song(
      id: 'd',
      title: 'Delta',
      fileName: 'd.mp3',
      size: 400,
      checksum: 'chk_d',
      addedAt: DateTime(2026, 1, 4),
    );

    late LibraryService library;
    late PlayerService player;

    setUp(() {
      library = LibraryService();
      player = PlayerService(library);
    });

    tearDown(() {
      player.dispose();
    });

    test('updateQueue updates queue and preserves current song index', () {
      // Initial queue: [A, B, C]
      player.updateQueue([songA, songB, songC], sourceId: 'library', sourceTitle: 'Library');
      expect(player.queue.length, 3);
      expect(player.queue[0].id, 'a');
      expect(player.queueSourceId, 'library');

      // Set currentSong to songB
      player.currentSong = songB;
      player.updateQueue([songC, songB, songA]);

      // Queue is now [C, B, A], current song is B, index should be 1
      expect(player.queue[0].id, 'c');
      expect(player.queue[1].id, 'b');
      expect(player.queue[2].id, 'a');
      expect(player.queueIndex, 1);
    });

    test('updateQueue prepends currentSong if filtered out by favorites', () {
      player.currentSong = songA;
      
      // Filter contains only [B, C]
      player.updateQueue([songB, songC], sourceId: 'favorites', sourceTitle: 'Favorites');

      // Current song A should remain in queue at index 0
      expect(player.queue.first.id, 'a');
      expect(player.queueIndex, 0);
      expect(player.queue.length, 3);
      expect(player.queueSourceId, 'favorites');
    });

    test('Playlist queue source is isolated and preserved', () {
      // User starts a playlist
      player.updateQueue(
        [songB, songA],
        sourceId: 'playlist:pl_1',
        sourceTitle: 'My Playlist',
      );
      player.currentSong = songB;

      expect(player.queueSourceId, 'playlist:pl_1');
      expect(player.queue.length, 2);
      expect(player.queue[0].id, 'b');
      expect(player.queue[1].id, 'a');

      // When checking queue source, it is clearly identified as a playlist
      expect(player.queueSourceId?.startsWith('playlist:'), isTrue);
    });

    test('toggleSongLock toggles locked status correctly', () {
      expect(player.isSongLocked('b'), isFalse);
      expect(player.lockedSongIds.contains('b'), isFalse);

      player.toggleSongLock('b');
      expect(player.isSongLocked('b'), isTrue);
      expect(player.lockedSongIds.contains('b'), isTrue);

      player.toggleSongLock('b');
      expect(player.isSongLocked('b'), isFalse);
      expect(player.lockedSongIds.contains('b'), isFalse);
    });

    test('rerollUpcomingQueue preserves previous, current, and locked songs while refreshing unlocked upcoming songs', () async {
      final songD = Song(
        id: 'd',
        title: 'Delta',
        fileName: 'd.mp3',
        size: 400,
        checksum: 'chk_d',
        addedAt: DateTime(2026, 1, 4),
      );
      final songE = Song(
        id: 'e',
        title: 'Epsilon',
        fileName: 'e.mp3',
        size: 500,
        checksum: 'chk_e',
        addedAt: DateTime(2026, 1, 5),
      );

      // Queue: [A (past), B (current), C (unlocked upcoming), D (locked upcoming)]
      player.updateQueue([songA, songB, songC, songD]);
      player.currentSong = songB;
      player.updateQueue([songA, songB, songC, songD]); // queueIndex is 1

      // Add offline songs to library for offline recommendation fallback
      library.setSongsForTesting([songA, songB, songC, songD, songE]);

      // Lock song D
      player.toggleSongLock('d');
      expect(player.isSongLocked('d'), isTrue);

      final ok = await player.rerollUpcomingQueue();
      expect(ok, isTrue);

      // Song A and B are preserved (past and current)
      expect(player.queue[0].id, 'a');
      expect(player.queue[1].id, 'b');

      // Locked song D is preserved in upcoming queue
      expect(player.queue.any((s) => s.id == 'd'), isTrue);

      // Unlocked song C was removed and replaced by fallback/fresh recommendations (songE)
      expect(player.queue.any((s) => s.id == 'e'), isTrue);
    });

    test('autoRerollSeed toggles state and triggers automatic upcoming queue refresh', () async {
      final songD = Song(
        id: 'd',
        title: 'Delta',
        fileName: 'd.mp3',
        size: 400,
        checksum: 'chk_d',
        addedAt: DateTime(2026, 1, 4),
      );
      final songE = Song(
        id: 'e',
        title: 'Epsilon',
        fileName: 'e.mp3',
        size: 500,
        checksum: 'chk_e',
        addedAt: DateTime(2026, 1, 5),
      );

      player.updateQueue([songA, songB, songC, songD]);
      player.currentSong = songB;
      player.updateQueue([songA, songB, songC, songD]);
      library.setSongsForTesting([songA, songB, songC, songD, songE]);

      expect(player.autoRerollSeed, isFalse);

      player.toggleAutoRerollSeed();
      expect(player.autoRerollSeed, isTrue);

      // Await any microtasks/futures initiated by toggle
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Toggling off restores false
      player.toggleAutoRerollSeed();
      expect(player.autoRerollSeed, isFalse);

      player.setAutoRerollSeed(true);
      expect(player.autoRerollSeed, isTrue);
      player.setAutoRerollSeed(false);
      expect(player.autoRerollSeed, isFalse);
    });

    test('rerollNextTrackOnly selects only one next song and preserves locked songs', () async {
      final songD = Song(
        id: 'd',
        title: 'Delta',
        fileName: 'd.mp3',
        size: 400,
        checksum: 'chk_d',
        addedAt: DateTime(2026, 1, 4),
      );
      final songE = Song(
        id: 'e',
        title: 'Epsilon',
        fileName: 'e.mp3',
        size: 500,
        checksum: 'chk_e',
        addedAt: DateTime(2026, 1, 5),
      );

      player.updateQueue([songA, songB, songC, songD]);
      player.currentSong = songB;
      player.updateQueue([songA, songB, songC, songD]);
      library.setSongsForTesting([songA, songB, songC, songD, songE]);

      player.toggleSongLock('d');
      expect(player.isSongLocked('d'), isTrue);

      final ok = await player.rerollNextTrackOnly();
      expect(ok, isTrue);

      // Past and current preserved: [A, B]
      expect(player.queue[0].id, 'a');
      expect(player.queue[1].id, 'b');

      // Old next song (C) replaced with E; tail (D) preserved in place
      expect(player.queue.map((s) => s.id).toList(), ['a', 'b', 'e', 'd']);
    });

    test('autoRerollSeed with autoplay active swaps only the next track and preserves tail without expanding queue', () async {
      final songD = Song(
        id: 'd',
        title: 'Delta',
        fileName: 'd.mp3',
        size: 400,
        checksum: 'chk_d',
        addedAt: DateTime(2026, 1, 4),
      );
      final songE = Song(
        id: 'e',
        title: 'Epsilon',
        fileName: 'e.mp3',
        size: 500,
        checksum: 'chk_e',
        addedAt: DateTime(2026, 1, 5),
      );
      final songF = Song(
        id: 'f',
        title: 'Foxtrot',
        fileName: 'f.mp3',
        size: 600,
        checksum: 'chk_f',
        addedAt: DateTime(2026, 1, 6),
      );

      player.setAutoplay(true);
      player.updateQueue([songA, songB, songC, songD]);
      player.currentSong = songB;
      player.updateQueue([songA, songB, songC, songD]);
      library.setSongsForTesting([songA, songB, songC, songD, songE, songF]);

      final ok = await player.rerollNextTrackOnly();
      expect(ok, isTrue);

      // Auto-reroll only swaps the single next song (index 2); queue length remains 4 and tail (songD) is preserved
      expect(player.queue.length, 4);
      expect(player.queue[0].id, 'a');
      expect(player.queue[1].id, 'b');
      expect(player.queue[2].id, isNot('c'));
      expect(player.queue[3].id, 'd');
    });

    test('setScrubbingPosition updates scrubbingPosition and notifies listeners', () {
      Duration? receivedPos;
      player.scrubbingPositionNotifier.addListener(() {
        receivedPos = player.scrubbingPosition;
      });

      player.setScrubbingPosition(const Duration(seconds: 45));
      expect(player.scrubbingPosition, const Duration(seconds: 45));
      expect(receivedPos, const Duration(seconds: 45));

      player.setScrubbingPosition(null);
      expect(player.scrubbingPosition, isNull);
      expect(receivedPos, isNull);
    });

    test('volume setting preserves low and zero levels without blasting to 1.0', () async {
      await player.setVolume(0.02);
      expect(player.volume, closeTo(0.02, 0.001));

      await player.setVolume(0.0);
      expect(player.volume, 0.0);
    });

    test('removeFromQueue and stop clean up shuffle and locked tracks cleanly', () async {
      player.updateQueue([songA, songB, songC]);
      player.currentSong = songA;
      player.toggleShuffle();
      expect(player.shuffle, isTrue);
      player.toggleSongLock('b');
      expect(player.isSongLocked('b'), isTrue);

      player.removeFromQueue(1); // removes songB
      expect(player.queue.length, 2);
      expect(player.isSongLocked('b'), isFalse);

      await player.stop();
      expect(player.queue.isEmpty, isTrue);
      expect(player.currentSong, isNull);
    });

    test('removeSongsFromQueue removes multiple tracks atomically and updates queue bounds', () {
      player.updateQueue([songA, songB, songC]);
      player.currentSong = songA;

      player.removeSongsFromQueue({'b', 'c'});
      expect(player.queue.length, 1);
      expect(player.queue.first.id, 'a');
    });

    test('setSleepTimer and cancelSleepTimer manage state cleanly', () {
      expect(player.isSleepTimerActive, isFalse);

      player.setSleepTimer(null, endOfSong: true);
      expect(player.isSleepTimerActive, isTrue);
      expect(player.sleepTimerEndOfSong, isTrue);

      player.cancelSleepTimer();
      expect(player.isSleepTimerActive, isFalse);
      expect(player.sleepTimerEndOfSong, isFalse);
    });

    test('previous() wraps around to end of queue when LoopSetting.all is active at index 0', () async {
      player.currentSong = songA;
      player.updateQueue([songA, songB, songC]);
      expect(player.queueIndex, 0);

      // Loop setting all
      player.toggleLoop();
      expect(player.loopMode, LoopSetting.all);

      await player.previous();
      expect(player.queueIndex, 2);
      expect(player.currentSong?.id, 'c');
    });

    test('RecommendationService.extractVideoId extracts 11-char IDs from raw, bracketed, and stream formats', () {
      expect(RecommendationService.extractVideoId('dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
      expect(RecommendationService.extractVideoId('Song [dQw4w9WgXcQ].m4a'), 'dQw4w9WgXcQ');
      expect(RecommendationService.extractVideoId('stream_dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
      expect(RecommendationService.extractVideoId('https://www.youtube.com/watch?v=dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    });

    test('stop() clears currentSong, queue, and synchronizes with PearAudioHandler', () async {
      final handler = PearAudioHandler();
      final playerWithHandler = PlayerService(library, audioHandler: handler);

      playerWithHandler.currentSong = songA;
      playerWithHandler.updateQueue([songA, songB]);
      expect(playerWithHandler.queue.length, 2);
      expect(playerWithHandler.currentSong?.id, 'a');

      await handler.stop();

      expect(playerWithHandler.currentSong, isNull);
      expect(playerWithHandler.queue, isEmpty);
      expect(playerWithHandler.queueIndex, -1);
      expect(handler.mediaItem.valueOrNull, isNull);

      playerWithHandler.dispose();
    });

    test('playNext inserts track at queueIndex + 1 and preserves currentSong', () {
      player.updateQueue([songA, songB]);
      player.currentSong = songA;

      player.playNext(songC);
      expect(player.queue.length, 3);
      expect(player.queue[0].id, 'a');
      expect(player.queue[1].id, 'c');
      expect(player.queue[2].id, 'b');
      expect(player.currentSong?.id, 'a');
      expect(player.queueIndex, 0);
    });

    test('addToQueue appends track to end of queue', () {
      player.updateQueue([songA, songB]);
      player.currentSong = songA;

      player.addToQueue(songC);
      expect(player.queue.length, 3);
      expect(player.queue[0].id, 'a');
      expect(player.queue[1].id, 'b');
      expect(player.queue[2].id, 'c');
      expect(player.currentSong?.id, 'a');
    });

    test('playNext and addToQueue unmark song from shufflePlayedSongIds', () {
      player.updateQueue([songA, songB, songC]);
      player.currentSong = songA;
      player.toggleShuffle();
      expect(player.shuffle, isTrue);

      player.playNext(songB);
      expect(player.queue[1].id, 'b');
    });

    test('addSongsToQueue batch inserts multiple songs correctly', () {
      player.updateQueue([songA]);
      player.currentSong = songA;

      player.addSongsToQueue([songB, songC]);
      expect(player.queue.length, 3);
      expect(player.queue[0].id, 'a');
      expect(player.queue[1].id, 'b');
      expect(player.queue[2].id, 'c');

      player.addSongsToQueue([songC], playNext: true);
      expect(player.queue.length, 4);
      expect(player.queue[0].id, 'a');
      expect(player.queue[1].id, 'c');
      expect(player.queue[2].id, 'b');
      expect(player.queue[3].id, 'c');
    });

    test('PlayerService setSpeed clamps within bounds and updates state', () async {
      expect(player.speed, 1.0);
      await player.setSpeed(1.5);
      expect(player.speed, 1.5);

      await player.setSpeed(0.1);
      expect(player.speed, 0.25);

      await player.setSpeed(4.0);
      expect(player.speed, 3.0);

      await player.setSpeed(1.0);
      expect(player.speed, 1.0);
    });

    test('PlayerService sleep timer endOfQueue manages active state and cancels cleanly', () {
      expect(player.isSleepTimerActive, isFalse);
      expect(player.sleepTimerEndOfQueue, isFalse);

      player.setSleepTimer(null, endOfQueue: true);
      expect(player.isSleepTimerActive, isTrue);
      expect(player.sleepTimerEndOfQueue, isTrue);
      expect(player.sleepTimerEndOfSong, isFalse);

      player.cancelSleepTimer();
      expect(player.isSleepTimerActive, isFalse);
      expect(player.sleepTimerEndOfQueue, isFalse);
    });

    test('PlayerService sleep timer endOfQueue suppresses repeat-all loop wrap', () async {
      player.updateQueue([songA, songB]);
      player.currentSong = songB; // at end of queue
      player.toggleLoop(); // LoopSetting.all
      expect(player.loopMode, LoopSetting.all);

      player.setSleepTimer(null, endOfQueue: true);
      expect(player.sleepTimerEndOfQueue, isTrue);

      // Advance at end of queue
      await player.next();
      expect(player.isSleepTimerActive, isFalse);
    });

    test('PlayerService cancelSleepTimer notifies listeners immediately', () {
      player.setSleepTimer(const Duration(minutes: 30));
      expect(player.isSleepTimerActive, isTrue);

      var notified = false;
      player.addListener(() {
        notified = true;
      });

      player.cancelSleepTimer();
      expect(player.isSleepTimerActive, isFalse);
      expect(player.sleepTimerRemaining, isNull);
      expect(notified, isTrue);
    });

    test('playNext places prior track immediately after currentSong (at N+1) on the first invocation and locks it', () {
      // Queue: [songA, songB, songC]
      player.updateQueue([songA, songB, songC]);
      player.currentSong = songB;
      expect(player.queueIndex, 1);

      // Play Next on songA (which is at index 0, prior to currentSong at index 1)
      player.playNext(songA);

      // In the resulting queue, songB is current (index 0), songA is immediately next (index 1), and songC follows (index 2)
      expect(player.queue.length, 3);
      expect(player.queue[0].id, 'b');
      expect(player.queue[1].id, 'a');
      expect(player.queue[2].id, 'c');
      expect(player.queueIndex, 0);
      expect(player.isSongLocked('a'), isTrue);
    });

    test('playNext on upcoming track moves it to N+1 and locks it', () {
      // Queue: [songA, songB, songC, songD]
      player.updateQueue([songA, songB, songC, songD]);
      player.currentSong = songA;
      expect(player.queueIndex, 0);

      // Play Next on songD (which was at the end of queue)
      player.playNext(songD);

      // songA remains at 0, songD is inserted at index 1 (N+1)
      expect(player.queue.length, 4);
      expect(player.queue[0].id, 'a');
      expect(player.queue[1].id, 'd');
      expect(player.queue[2].id, 'b');
      expect(player.queue[3].id, 'c');
      expect(player.queueIndex, 0);
      expect(player.isSongLocked('d'), isTrue);
    });

    test('addSongsToQueue with playNext: true places batch at N+1 and locks them', () {
      player.updateQueue([songA, songB]);
      player.currentSong = songA;
      expect(player.queueIndex, 0);

      player.addSongsToQueue([songC, songD], playNext: true);

      expect(player.queue.length, 4);
      expect(player.queue[0].id, 'a');
      expect(player.queue[1].id, 'c');
      expect(player.queue[2].id, 'd');
      expect(player.queue[3].id, 'b');
      expect(player.isSongLocked('c'), isTrue);
      expect(player.isSongLocked('d'), isTrue);
    });

    test('startRadio initializes radio queue and populates recommendations without session cancellation', () async {
      library.setSongsForTesting([songA, songB, songC, songD]);

      // Seed songA is currently not playing
      await player.startRadio(songA);

      expect(player.queueSourceId, 'radio');
      expect(player.queue.isNotEmpty, isTrue);
      expect(player.queue.first.id, 'a');
      expect(player.currentSong?.id, 'a');

      // Allow background recommendations to run
      final ok = await player.fetchAndAppendRecommendations();
      expect(ok, isTrue);
      expect(player.queue.length, greaterThan(1));
      expect(player.queueIndex, 0);
    });

    test('Song.fromJson parses null or floating point size safely and provides default checksum', () {
      final json1 = {
        'id': 'test1',
        'title': 'Test 1',
        'fileName': 'test1.mp3',
        'size': 1234.5,
      };
      final song1 = Song.fromJson(json1);
      expect(song1.size, 1234);
      expect(song1.checksum, '');

      final json2 = {
        'id': 'test2',
        'title': 'Test 2',
        'fileName': 'test2.mp3',
        'size': null,
      };
      final song2 = Song.fromJson(json2);
      expect(song2.size, 0);
      expect(song2.checksum, '');
    });

    test('next() honors locked song at queueIndex + 1 during shuffle mode', () async {
      player.updateQueue([songA, songB, songC, songD]);
      player.currentSong = songA;
      player.toggleShuffle();
      expect(player.shuffle, isTrue);

      // Lock songB at N+1 (simulating playNext)
      player.toggleSongLock('b');
      expect(player.isSongLocked('b'), isTrue);

      await player.next();

      // Should pick locked songB regardless of shuffle randomization
      expect(player.currentSong?.id, 'b');
    });
  });
}

