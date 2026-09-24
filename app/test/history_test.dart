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
    Widget buildHarness(
      AppController controller,
      HistoryService history,
    ) {
      return MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(value: controller),
          ChangeNotifierProvider<PlayerService>.value(
            value: controller.player,
          ),
          ChangeNotifierProvider<HistoryService>.value(value: history),
        ],
        child: const MaterialApp(home: HistoryScreen()),
      );
    }

    testWidgets('lists played songs newest first and clears on confirm',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final env = await createEnvironment();
      final local = _song('local_1', 'Local File');
      env.library.setSongsForTesting([local]);
      final streamSong = _song(
        'stream_abc123',
        'Online Stream Song',
        sourceDeviceId: 'stream',
      );
      await env.identity.registerOnlineSongs([streamSong]);

      env.history.record(local);
      env.history.record(streamSong);

      await tester.pumpWidget(buildHarness(env.controller, env.history));
      await tester.pumpAndSettle();

      expect(find.text('Online Stream Song'), findsOneWidget);
      expect(find.text('Local File'), findsOneWidget);
      // Newest first in reading order. Wide layouts may place the two songs
      // side by side in a grid, so only fall back to the x axis then.
      final firstPos = tester.getTopLeft(find.text('Online Stream Song'));
      final secondPos = tester.getTopLeft(find.text('Local File'));
      final newestFirst = firstPos.dy < secondPos.dy ||
          (firstPos.dy == secondPos.dy && firstPos.dx < secondPos.dx);
      expect(newestFirst, isTrue);

      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Clear listening history?'), findsOneWidget);

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(env.history.isEmpty, isTrue);
      expect(find.text('Nothing played yet'), findsOneWidget);
    });

    testWidgets('shows the empty state when nothing has played', (tester) async {
      final env = await createEnvironment();
      await tester.pumpWidget(buildHarness(env.controller, env.history));
      await tester.pumpAndSettle();

      expect(find.text('Nothing played yet'), findsOneWidget);
      // No clear action while the list is empty.
      expect(find.byIcon(Icons.delete_sweep_outlined), findsNothing);
    });

    testWidgets('rows show when each song was played', (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final env = await createEnvironment();
      final local = _song('local_1', 'Local File');
      env.library.setSongsForTesting([local]);
      env.history.record(
        local,
        at: DateTime.now().subtract(const Duration(hours: 3)),
      );

      await tester.pumpWidget(buildHarness(env.controller, env.history));
      await tester.pumpAndSettle();

      expect(find.textContaining('3 h ago'), findsOneWidget);
    });
  });
}
