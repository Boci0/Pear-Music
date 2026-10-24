import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/screens/history_screen.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(
  String id,
  String title, {
  String? sourceDeviceId,
  String? fileName,
}) =>
    Song(
      id: id,
      title: title,
      fileName: fileName ?? '$id.mp3',
      size: 1024,
      checksum: 'chk_$id',
      sourceDeviceId: sourceDeviceId,
      addedAt: DateTime(2026, 9, 21),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return Directory.systemTemp.path;
    });
  });

  Future<
      ({
        AppController controller,
        LibraryService library,
        PlayerService player,
        IdentityService identity,
        HistoryService history,
      })> createEnvironment() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final history = HistoryService(prefs);
    final player = PlayerService(library, identity: identity, history: history);
    final controller = AppController(
      identity: identity,
      library: library,
      player: player,
      youtube: YoutubeService(),
      history: history,
    );
    return (
      controller: controller,
      library: library,
      player: player,
      identity: identity,
      history: history,
    );
  }

  group('HistoryService', () {
    test('keeps the newest play first and does not duplicate repeats', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final history = HistoryService(prefs);

      history.record(_song('a', 'Song A'));
      history.record(_song('b', 'Song B'));
      history.record(_song('a', 'Song A'));

      expect(history.length, 2);
      expect(history.entries.map((e) => e.songId).toList(), ['a', 'b']);
      expect(history.entries.first.songId, 'a');
    });

    test('caps the log at maxEntries and drops the oldest plays', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final history = HistoryService(prefs);

      for (var i = 0; i < HistoryService.maxEntries + 25; i++) {
        history.record(_song('s$i', 'Song $i'));
      }

      expect(history.length, HistoryService.maxEntries);
      expect(history.entries.first.songId, 's${HistoryService.maxEntries + 24}');
      expect(history.contains('s24'), isFalse);
    });

    test('persists to prefs and reloads in a fresh instance', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final history = HistoryService(prefs);

      history.record(_song('local_1', 'Local One'));
      history.record(_song('stream_abc', 'Stream Song'));

      final reloaded = HistoryService(prefs);
      expect(reloaded.length, 2);
      expect(reloaded.entries.map((e) => e.songId).toList(), [
        'stream_abc',
        'local_1',
      ]);
    });

    test('ignores corrupt stored history instead of throwing', () async {
      SharedPreferences.setMockInitialValues({
        HistoryService.prefsKey: 'not json at all',
      });
      final prefs = await SharedPreferences.getInstance();
      final history = HistoryService(prefs);
      expect(history.isEmpty, isTrue);
    });

    test('prune drops unreachable entries and clear empties the log', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final history = HistoryService(prefs);

      history.record(_song('keep', 'Keep'));
      history.record(_song('gone', 'Gone'));
      history.prune((id) => id == 'keep');
      expect(history.entries.map((e) => e.songId).toList(), ['keep']);

      await history.clear();
      expect(history.isEmpty, isTrue);
      expect(prefs.getString(HistoryService.prefsKey), isNull);
    });
  });

  group('AppController.historySongs', () {
    test('resolves library and online entries newest first, skipping gone songs',
        () async {
      final env = await createEnvironment();
      final local = _song('local_1', 'Local One');
      env.library.setSongsForTesting([local]);
      final streamSong = _song(
        'stream_abc123',
        'Online Song',
        sourceDeviceId: 'stream',
      );
      await env.identity.registerOnlineSongs([streamSong]);

      env.history.record(local);
      env.history.record(streamSong);
      env.history.record(_song('deleted', 'Deleted Song'));

      final resolved = env.controller.historySongs;
      expect(resolved.map((s) => s.id).toList(), ['stream_abc123', 'local_1']);
      expect(resolved.first.title, 'Online Song');
      expect(resolved.last.title, 'Local One');
    });

    test('shows one row when a stream and its downloaded copy were both played',
        () async {
      final env = await createEnvironment();
      const videoId = 'dQw4w9WgXcQ';
      final downloaded = _song(
        'local_copy',
        'Downloaded Copy',
        fileName: 'Downloaded Copy [$videoId].m4a',
      );
      env.library.setSongsForTesting([downloaded]);
      final streamSong = _song(
        'stream_$videoId',
        'Streamed Copy',
        sourceDeviceId: 'stream',
      );
      await env.identity.registerOnlineSongs([streamSong]);

      env.history.record(streamSong); // older
      env.history.record(downloaded); // newer play of the same video

      final resolved = env.controller.historySongs;
      expect(resolved, hasLength(1));
      expect(resolved.single.id, 'local_copy');
    });

    test('clearHistory empties the list', () async {
      final env = await createEnvironment();
      final local = _song('local_1', 'Local One');
      env.library.setSongsForTesting([local]);
      env.history.record(local);

      expect(env.controller.historySongs, hasLength(1));
      await env.controller.clearHistory();
      expect(env.controller.historySongs, isEmpty);
      expect(env.history.isEmpty, isTrue);
    });
  });

  group('PlayerService history wiring', () {
    test('playSong records the song that started playing', () async {
      final env = await createEnvironment();
      final song = _song('local_1', 'Local One');
      env.library.setSongsForTesting([song]);

      await env.player.playSong(song, queue: [song]);

      expect(env.history.length, 1);
      expect(env.history.entries.first.songId, 'local_1');
      env.player.dispose();
    });
  });


  group('HistoryScreen', () {
    Future<void> pumpAt(
      WidgetTester tester,
      Size size,
      AppController controller,
      HistoryService history,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppController>.value(value: controller),
            ChangeNotifierProvider<PlayerService>.value(
              value: controller.player,
            ),
            ChangeNotifierProvider<HistoryService>.value(value: history),
          ],
          child: const MaterialApp(home: HistoryScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    // Three plays on three days: today, yesterday and five days back.
    Future<
        ({
          AppController controller,
          HistoryService history,
          DateTime older,
        })> playedOverThreeDays() async {
      final env = await createEnvironment();
      final today = _song('t', 'Played Today');
      final yesterday = _song('y', 'Played Yesterday');
      final older = _song('o', 'Played Earlier');
      env.library.setSongsForTesting([today, yesterday, older]);
      final now = DateTime.now();
      final olderAt = now.subtract(const Duration(days: 5));
      env.history.record(older, at: olderAt);
      env.history.record(yesterday, at: now.subtract(const Duration(days: 1)));
      env.history.record(today, at: now);
      return (
        controller: env.controller,
        history: env.history,
        older: olderAt,
      );
    }

    for (final size in const [Size(430, 920), Size(1440, 900)]) {
      testWidgets('groups plays under day headers at ${size.width.toInt()} px',
          (tester) async {
        final env = await playedOverThreeDays();
        await pumpAt(tester, size, env.controller, env.history);

        expect(find.text('HISTORY'), findsOneWidget);
        expect(find.byIcon(Icons.delete_sweep_outlined), findsOneWidget);
        final olderLabel = historyDayLabel(env.older, DateTime.now());
        final order = [
          'TODAY',
          'Played Today',
          'YESTERDAY',
          'Played Yesterday',
          olderLabel,
          'Played Earlier',
        ].map((t) => tester.getTopLeft(find.text(t)).dy).toList();
        for (var i = 1; i < order.length; i++) {
          expect(order[i], greaterThan(order[i - 1]));
        }
        // The old "3 h ago" meta is replaced by the time of day.
        expect(find.textContaining('ago'), findsNothing);
      });
    }

    testWidgets('clear history empties the list into the empty state',
        (tester) async {
      final env = await playedOverThreeDays();
      await pumpAt(tester, const Size(430, 920), env.controller, env.history);

      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(env.history.isEmpty, isTrue);
      expect(find.text('NOTHING PLAYED YET'), findsOneWidget);
    });

    for (final size in const [Size(430, 920), Size(1440, 900)]) {
      testWidgets('empty state at ${size.width.toInt()} px', (tester) async {
        final env = await createEnvironment();
        await pumpAt(tester, size, env.controller, env.history);

        expect(find.text('NOTHING PLAYED YET'), findsOneWidget);
        expect(find.text('GO TO LIBRARY'), findsOneWidget);
        expect(find.byIcon(Icons.delete_sweep_outlined), findsNothing);
      });
    }

    test('day labels count calendar days', () {
      final now = DateTime(2026, 9, 30, 1, 0);
      expect(historyDayLabel(DateTime(2026, 9, 30, 0, 10), now), 'TODAY');
      expect(historyDayLabel(DateTime(2026, 9, 29, 23, 0), now), 'YESTERDAY');
      expect(historyDayLabel(DateTime(2026, 9, 28, 23, 0), now), '28 SEP');
      expect(historyDayLabel(DateTime(2025, 9, 28), now), '28 SEP 2025');
    });
  });

  group('played-ago label', () {
    final now = DateTime(2026, 9, 30, 1, 0); // Wednesday, 1 am

    test('counts calendar days, not 24-hour blocks', () {
      // Monday 23:00 is 26 hours back, but two days ago, not yesterday.
      expect(playedAgo(DateTime(2026, 9, 28, 23, 0), now), '2 days ago');
      // Tuesday 00:30 is 24.5 hours back and was yesterday.
      expect(playedAgo(DateTime(2026, 9, 29, 0, 30), now), 'yesterday');
    });

    test('recent plays keep their minutes and hours', () {
      expect(playedAgo(DateTime(2026, 9, 30, 0, 50), now), '10 min ago');
      // Late last night is still counted in hours within a day.
      expect(playedAgo(DateTime(2026, 9, 29, 22, 0), now), '3 h ago');
      expect(playedAgo(DateTime(2026, 9, 20), now), '20 Sep');
    });
  });
}
