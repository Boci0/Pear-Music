import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/screens/explore_screen.dart';
import 'package:peerm_app/screens/home_screen.dart';
import 'package:peerm_app/screens/playlists_screen.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/loudness_service.dart';
import 'package:peerm_app/services/lyrics_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/player_theme.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';
import 'package:peerm_app/services/video_relay.dart';
import 'package:peerm_app/services/youtube_search_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/now_playing_panel.dart';
import 'package:peerm_app/widgets/song_tile.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _localSong(
  String id,
  String title, {
  String? fileName,
  int size = 4404019,
  int? durationMs,
  String? artist,
}) => Song(
  id: id,
  title: title,
  fileName: fileName ?? '$title.mp3',
  size: size,
  checksum: 'chk_$id',
  durationMs: durationMs,
  artist: artist,
  addedAt: DateTime(2026, 2, 1),
);

Song _streamSong(String videoId, String title, {String? artist}) => Song(
  id: 'stream_$videoId',
  title: title,
  fileName: '$title [$videoId].m4a',
  size: 3200000,
  checksum: 'stream_$videoId',
  sourceDeviceId: 'stream',
  artist: artist,
  addedAt: DateTime(2026, 2, 1),
);

class _RecordingYoutubeService extends YoutubeService {
  final List<({String url, String? artist})> embeddedCalls = [];
  final List<({String url, String? artist})> desktopCalls = [];
  final Directory sourceDir;

  _RecordingYoutubeService(this.sourceDir);

  int _sampleSeq = 1;

  Future<Song?> _createSample(
    LibraryService library,
    String videoId,
    String title,
    String? artist,
  ) async {
    final seed = _sampleSeq++;
    final sample = File(p.join(sourceDir.path, '$title [$videoId].m4a'))
      ..writeAsBytesSync(List.generate(64, (i) => (i + seed) % 251));
    return library.addScrapedFile(sample, title: title, artist: artist);
  }

  @override
  Future<Song?> scrapeAndAddWithEmbeddedYtDlp(
    LibraryService library,
    String url, {
    String? preferredArtwork,
    String? artist,
    YoutubeStatusCallback? onStatus,
    YoutubeProgressCallback? onProgress,
    DownloadCancellation? cancel,
  }) async {
    embeddedCalls.add((url: url, artist: artist));
    return _createSample(library, 'abcd1234567', 'Embedded Song', artist);
  }

  @override
  Future<Song?> scrapeAndAddWithYtDlp(
    LibraryService library,
    String url, {
    String? preferredArtwork,
    String? artist,
    YoutubeStatusCallback? onStatus,
    YoutubeProgressCallback? onProgress,
    DownloadCancellation? cancel,
    int? videoHeight,
  }) async {
    desktopCalls.add((url: url, artist: artist));
    return _createSample(library, 'efgh7654321', 'Desktop Song', artist);
  }
}

class _RelayUpstream {
  _RelayUpstream(this.body);

  final Uint8List body;
  late final HttpServer server;
  bool refuse = false;
  int requests = 0;

  String get url => 'http://127.0.0.1:${server.port}/video.mp4';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests++;
      if (refuse) {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      final range = req.headers.value(HttpHeaders.rangeHeader) ?? '';
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      final start = m == null ? 0 : int.parse(m.group(1)!);
      final endRaw = m?.group(2) ?? '';
      final end = endRaw.isEmpty
          ? body.length - 1
          : int.parse(endRaw).clamp(0, body.length - 1);
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers
        ..set('content-range', 'bytes $start-$end/${body.length}')
        ..contentLength = end - start + 1;
      req.response.add(body.sublist(start, end + 1));
      await req.response.close();
    });
  }
}

Future<({int status, List<int> body})> _relayGet(Uri url, String range) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(url);
    req.headers.set(HttpHeaders.rangeHeader, range);
    final res = await req.close();
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    return (status: res.statusCode, body: bytes);
  } finally {
    client.close(force: true);
  }
}

class _FakePlayer extends AudioPlayer {
  _FakePlayer() : super(handleAudioSessionActivation: false);

  final List<String> loaded = [];
  Duration position_ = Duration.zero;
  Duration? duration_ = const Duration(minutes: 3);
  ProcessingState processingState_ = ProcessingState.ready;
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
    if (initialPosition != null) position_ = initialPosition;
    return duration_;
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
  }

  @override
  Future<void> play() async => _playing = true;

  @override
  Future<void> pause() async => _playing = false;

  @override
  Future<void> stop() async => _playing = false;

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (position != null) position_ = position;
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setLoopMode(LoopMode mode) async {}
}

class _FixedRandom implements math.Random {
  final int fixed;
  _FixedRandom(this.fixed);

  @override
  int nextInt(int max) => fixed % max;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0.0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;

  setUpAll(() {
    sandbox = Directory.systemTemp.createTempSync('peerm_batch_612_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => sandbox.path);
  });

  tearDownAll(() {
    LoudnessService.debugSupportedOverride = null;
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  tearDown(() {
    YouTubeSearchService.dispose();
    LyricsService.clearMemoryCache();
  });

  group('Fix 1: StreamCacheManager.saveToLibrary embedded routing', () {
    test('uses embedded yt-dlp on phone and desktop yt-dlp when false, keeping artist',
        () async {
      final work = Directory(p.join(sandbox.path, 'fix1'))..createSync();
      final lib = LibraryService()..debugBaseDirectory = work;
      await lib.init();
      final fakeYt = _RecordingYoutubeService(work);

      final phoneSong = _streamSong(
        'abcd1234567',
        'Track One',
        artist: 'Phone Artist',
      );
      final savedPhone = await StreamCacheManager.saveToLibrary(
        phoneSong,
        lib,
        youtube: fakeYt,
        useEmbeddedYtDlp: true,
      );
      expect(savedPhone, isNotNull);
      expect(savedPhone!.artist, 'Phone Artist');
      expect(fakeYt.embeddedCalls.length, 1);
      expect(
        fakeYt.embeddedCalls.first.url,
        'https://www.youtube.com/watch?v=abcd1234567',
      );
      expect(fakeYt.embeddedCalls.first.artist, 'Phone Artist');
      expect(fakeYt.desktopCalls, isEmpty);

      final desktopSong = _streamSong(
        'efgh7654321',
        'Track Two',
        artist: 'Desktop Artist',
      );
      final savedDesktop = await StreamCacheManager.saveToLibrary(
        desktopSong,
        lib,
        youtube: fakeYt,
        useEmbeddedYtDlp: false,
      );
      expect(savedDesktop, isNotNull);
      expect(savedDesktop!.artist, 'Desktop Artist');
      expect(fakeYt.desktopCalls.length, 1);
      expect(fakeYt.desktopCalls.first.artist, 'Desktop Artist');
    });

    test('promotes already cached stream file in 0ms without calling yt-dlp',
        () async {
      final work = Directory(p.join(sandbox.path, 'fix1_cached'))..createSync();
      final lib = LibraryService()..debugBaseDirectory = work;
      await lib.init();
      final fakeYt = _RecordingYoutubeService(work);

      final cacheDir = await StreamCacheManager.getCacheDirectory();
      const videoId = 'cach1234567';
      final cachedFile = File(p.join(cacheDir.path, '$videoId.m4a'))
        ..writeAsBytesSync(List.filled(60000, 9));
      addTearDown(() async {
        if (await cachedFile.exists()) await cachedFile.delete();
      });

      final song = _streamSong(videoId, 'Cached Song', artist: 'Cached Artist');
      final saved = await StreamCacheManager.saveToLibrary(
        song,
        lib,
        youtube: fakeYt,
        useEmbeddedYtDlp: true,
      );

      expect(saved, isNotNull);
      expect(saved!.title, 'Cached Song');
      expect(saved.artist, 'Cached Artist');
      expect(fakeYt.embeddedCalls, isEmpty);
      expect(fakeYt.desktopCalls, isEmpty);
      expect(await cachedFile.exists(), isTrue);
    });
  });

  group('Fix 2: VideoRelay relink resets after completion', () {
    test('refreshes a second expired link after an earlier relink', () async {
      final size = VideoRelay.windowBytes * 2 + 1024;
      final bodyA = Uint8List.fromList(List.filled(size, 65));
      final bodyB = Uint8List.fromList(List.filled(size, 66));
      final bodyC = Uint8List.fromList(List.filled(size, 67));
      final serverA = _RelayUpstream(bodyA)..refuse = true;
      final serverB = _RelayUpstream(bodyB);
      final serverC = _RelayUpstream(bodyC);
      await serverA.start();
      await serverB.start();
      await serverC.start();

      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      var relinkCalls = 0;
      try {
        final local = await VideoRelay.serve(
          serverA.url,
          client: HttpClient(),
          relink: () async {
            relinkCalls++;
            final target = relinkCalls == 1 ? serverB.url : serverC.url;
            return (url: target, headers: const <String, String>{});
          },
        );

        // Concurrent initial requests hit serverA (403), coalesce into 1 relink.
        final firstPair = await Future.wait([
          _relayGet(local, 'bytes=0-'),
          _relayGet(local, 'bytes=0-'),
        ]);
        expect(firstPair[0].status, 206);
        expect(firstPair[1].status, 206);
        expect(firstPair[0].body.first, 66);
        expect(relinkCalls, 1);

        // Later in playback, serverB expires (403); a second relink must occur.
        serverB.refuse = true;
        final nextWindow = await _relayGet(
          local,
          'bytes=${VideoRelay.windowBytes}-',
        );
        expect(nextWindow.status, 206);
        expect(nextWindow.body.first, 67);
        expect(relinkCalls, 2);
      } finally {
        HttpOverrides.global = overrides;
        VideoRelay.stop();
        await serverA.server.close(force: true);
        await serverB.server.close(force: true);
        await serverC.server.close(force: true);
      }
    });
  });

  group('Fix 3: Explore link resolution and search error surfacing', () {
    test('extractDirectVideoId handles supported video URLs and ignores words', () {
      expect(
        YouTubeSearchService.extractDirectVideoId(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        ),
        'dQw4w9WgXcQ',
      );
      expect(
        YouTubeSearchService.extractDirectVideoId(
          'https://youtu.be/dQw4w9WgXcQ?si=share',
        ),
        'dQw4w9WgXcQ',
      );
      expect(
        YouTubeSearchService.extractDirectVideoId(
          'https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RD1',
        ),
        'dQw4w9WgXcQ',
      );
      expect(
        YouTubeSearchService.extractDirectVideoId(
          'youtube.com/shorts/abcd1234567',
        ),
        'abcd1234567',
      );
      expect(
        YouTubeSearchService.extractDirectVideoId(
          'youtu.be/wxyz9876543',
        ),
        'wxyz9876543',
      );
      expect(
        YouTubeSearchService.extractDirectVideoId(
          'https://m.youtube.com/live/live1234567',
        ),
        'live1234567',
      );
      expect(
        YouTubeSearchService.extractDirectVideoId(
          'https://www.youtube.com/embed/embd1234567',
        ),
        'embd1234567',
      );
      // Plain 11-char words or multi-word queries must NOT be treated as URLs.
      expect(YouTubeSearchService.extractDirectVideoId('radioactive'), isNull);
      expect(YouTubeSearchService.extractDirectVideoId('interstella'), isNull);
      expect(
        YouTubeSearchService.extractDirectVideoId(
          'check https://youtu.be/dQw4w9WgXcQ',
        ),
        isNull,
      );
      expect(
        YouTubeSearchService.extractDirectVideoId(
          'https://example.com/watch?v=dQw4w9WgXcQ',
        ),
        isNull,
      );
      expect(
        YouTubeSearchService.extractDirectVideoId(
          'https://www.youtube.com/playlist?list=PL12345',
        ),
        isNull,
      );
    });

    test('search propagates errors only when throwOnError is true', () async {
      YouTubeSearchService.debugSearchOverride =
          (q, {required limit, required enableVideos}) async {
            throw const SocketException('offline');
          };

      expect(await YouTubeSearchService.search('lofi'), isEmpty);
      await expectLater(
        YouTubeSearchService.search('lofi', throwOnError: true),
        throwsA(isA<SocketException>()),
      );

      YouTubeSearchService.debugSetLiveClient(
        MockClient((_) async => http.Response('err', 503)),
      );
      expect(await YouTubeSearchService.searchLive('radio'), isEmpty);
      await expectLater(
        YouTubeSearchService.searchLive('radio', throwOnError: true),
        throwsA(isA<HttpException>()),
      );
    });

    testWidgets('ExploreScreen shows SEARCH FAILED on error and retries cleanly',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final identity = IdentityService(prefs);
      final library = LibraryService();
      final history = HistoryService(prefs);
      final player = PlayerService(library, identity: identity, history: history);
      addTearDown(player.dispose);
      final controller = AppController(
        identity: identity,
        library: library,
        player: player,
        youtube: YoutubeService(),
        history: history,
      );

      var shouldFail = true;
      YouTubeSearchService.debugSearchOverride =
          (q, {required limit, required enableVideos}) async {
            if (shouldFail) throw const SocketException('no route');
            return [
              YouTubeSearchResult(
                videoId: 'ok123456789',
                title: 'Recovered Track',
                author: 'Test Artist',
                duration: const Duration(minutes: 3),
              ),
            ];
          };
      YouTubeSearchService.debugVideoLookup = (id) async => YouTubeSearchResult(
        videoId: id,
        title: 'Direct Link Track',
        author: 'Direct Artist',
        duration: const Duration(minutes: 2, seconds: 30),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppController>.value(value: controller),
            ChangeNotifierProvider<PlayerService>.value(value: player),
            ChangeNotifierProvider<IdentityService>.value(value: identity),
            ChangeNotifierProvider<LibraryService>.value(value: library),
            ChangeNotifierProvider<HistoryService>.value(value: history),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ExploreScreen(isActive: false)),
          ),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'lofi');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('SEARCH FAILED'), findsOneWidget);
      expect(
        find.text('Could not reach the server. Check your internet connection.'),
        findsOneWidget,
      );
      expect(find.text('NO SONGS FOUND FOR "LOFI"'), findsNothing);

      shouldFail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Recovered Track'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField),
        'https://youtu.be/dQw4w9WgXcQ',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Direct Link Track'), findsOneWidget);
    });
  });

  group('Fix 4: Downloads filter and SongTile duplicate file size', () {
    testWidgets('Downloads chip filters downloaded tracks and shows empty state',
        (tester) async {
      tester.view.physicalSize = const Size(430, 920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late AppController controller;
      late PlayerService player;
      late IdentityService identity;
      late LibraryService library;
      late HistoryService history;
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        identity = IdentityService(prefs);
        final work = Directory(p.join(sandbox.path, 'fix4_empty'))
          ..createSync(recursive: true);
        library = LibraryService()..debugBaseDirectory = work;
        await library.init();
        library.setSongsForTesting([
          _localSong('local1', 'Local Only Song', durationMs: 120000),
        ]);
        history = HistoryService(prefs);
        player = PlayerService(library, identity: identity, history: history);
        controller = AppController(
          identity: identity,
          library: library,
          player: player,
          youtube: YoutubeService(),
          history: history,
        );
      });
      addTearDown(player.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppController>.value(value: controller),
            ChangeNotifierProvider<PlayerService>.value(value: player),
            ChangeNotifierProvider<IdentityService>.value(value: identity),
            ChangeNotifierProvider<LibraryService>.value(value: library),
            ChangeNotifierProvider<HistoryService>.value(value: history),
          ],
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Local Only Song'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chip_downloads')));
      await tester.pumpAndSettle();

      expect(find.text('Local Only Song'), findsNothing);
      expect(find.text('NO DOWNLOADED SONGS YET'), findsOneWidget);
      expect(find.text('EXPLORE MUSIC'), findsOneWidget);
    });

    testWidgets('Select all in Downloads selects only downloaded songs',
        (tester) async {
      tester.view.physicalSize = const Size(430, 920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late AppController controller;
      late PlayerService player;
      late IdentityService identity;
      late LibraryService library;
      late HistoryService history;
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        identity = IdentityService(prefs);
        final work = Directory(p.join(sandbox.path, 'fix4_dl'))
          ..createSync(recursive: true);
        library = LibraryService()..debugBaseDirectory = work;
        await library.init();
        library.setSongsForTesting([
          _localSong(
            'dl1',
            'Downloaded Track',
            fileName: 'Downloaded Track [dQw4w9WgXcQ].m4a',
            durationMs: 180000,
          ),
          _localSong('local1', 'Local Only Track', durationMs: 180000),
        ]);
        history = HistoryService(prefs);
        player = PlayerService(library, identity: identity, history: history);
        controller = AppController(
          identity: identity,
          library: library,
          player: player,
          youtube: YoutubeService(),
          history: history,
        );
      });
      addTearDown(player.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppController>.value(value: controller),
            ChangeNotifierProvider<PlayerService>.value(value: player),
            ChangeNotifierProvider<IdentityService>.value(value: identity),
            ChangeNotifierProvider<LibraryService>.value(value: library),
            ChangeNotifierProvider<HistoryService>.value(value: history),
          ],
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('chip_downloads')));
      await tester.pumpAndSettle();

      expect(find.text('Downloaded Track'), findsOneWidget);
      expect(find.text('Local Only Track'), findsNothing);
      expect(find.text('1 songs'), findsOneWidget);

      await tester.longPress(find.text('Downloaded Track'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('SongTile suppresses duplicate size when duration is unknown',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final identity = IdentityService(prefs);
      final library = LibraryService();
      final history = HistoryService(prefs);
      final player = PlayerService(library, identity: identity, history: history);
      addTearDown(player.dispose);
      final controller = AppController(
        identity: identity,
        library: library,
        player: player,
        youtube: YoutubeService(),
        history: history,
      );

      final unknownLength = _localSong('u1', 'No Length', durationMs: null);
      final knownLength = _localSong('k1', 'With Length', durationMs: 180000);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppController>.value(value: controller),
            ChangeNotifierProvider<PlayerService>.value(value: player),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                child: Column(
                  children: [
                    SongTile(
                      song: unknownLength,
                      queue: [unknownLength],
                      metaSuffix: unknownLength.sizeLabel,
                    ),
                    SongTile(
                      song: unknownLength,
                      queue: [unknownLength],
                      metaSuffix: '15:30',
                    ),
                    SongTile(
                      song: knownLength,
                      queue: [knownLength],
                      metaSuffix: knownLength.sizeLabel,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Local · 4.2 MB'), findsOneWidget);
      expect(find.text('Local · 4.2 MB · 4.2 MB'), findsNothing);
      expect(find.text('Local · 4.2 MB · 15:30'), findsOneWidget);
      expect(find.text('Local · 3:00 · 4.2 MB'), findsOneWidget);
    });
  });

  group('Fix 5: Playlist active state and random shuffle start', () {
    testWidgets('only the playlist owning queueSourceId shows active',
        (tester) async {
      late AppController controller;
      late PlayerService player;
      late Song shared;
      late String p1Id;
      late String p1Name;
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final identity = IdentityService(prefs);
        final work = Directory(p.join(sandbox.path, 'fix5_ui'))
          ..createSync(recursive: true);
        final library = LibraryService()..debugBaseDirectory = work;
        await library.init();
        shared = _localSong('s1', 'Shared Song');
        library.setSongsForTesting([shared]);
        final p1 = await library.createPlaylist('Playlist One');
        final p2 = await library.createPlaylist('Playlist Two');
        await library.addSongToPlaylist(p1.id, shared.id);
        await library.addSongToPlaylist(p2.id, shared.id);
        p1Id = p1.id;
        p1Name = p1.name;

        final history = HistoryService(prefs);
        player = PlayerService(
          library,
          identity: identity,
          history: history,
          player: _FakePlayer(),
        );
        player.updateQueue([shared], sourceId: 'library', sourceTitle: 'Library');
        player.currentSong = shared;

        controller = AppController(
          identity: identity,
          library: library,
          player: player,
          youtube: YoutubeService(),
          history: history,
        );
        // Simulate AppController.init()'s player forwarding without invoking warm-up I/O.
        player.addListener(controller.notifyListeners);
      });
      addTearDown(() {
        player.removeListener(controller.notifyListeners);
        player.dispose();
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppController>.value(value: controller),
            ChangeNotifierProvider<PlayerService>.value(value: player),
          ],
          child: const MaterialApp(home: PlaylistsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Playing from Library must not mark either playlist as active/Resume.
      expect(find.byTooltip('Resume'), findsNothing);
      expect(find.byTooltip('Play all'), findsNWidgets(2));

      // Now switch active queueSourceId to Playlist One only.
      player.updateQueue(
        [shared],
        sourceId: 'playlist:$p1Id',
        sourceTitle: p1Name,
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Resume'), findsOneWidget);
      expect(find.byTooltip('Play all'), findsOneWidget);
    });

    test('playPlaylist with shuffle starts at a random track and enables shuffle',
        () async {
      LoudnessService.debugSupportedOverride = false;
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final identity = IdentityService(prefs);
      final work = Directory(p.join(sandbox.path, 'fix5_play'))..createSync();
      final library = LibraryService()..debugBaseDirectory = work;
      await library.init();

      final libDir = Directory(p.join(work.path, 'library'))..createSync();
      final songs = <Song>[];
      for (var i = 0; i < 4; i++) {
        final s = _localSong('p_$i', 'Track $i', fileName: 'p_$i.mp3');
        File(p.join(libDir.path, 'p_$i.mp3')).writeAsBytesSync([1, 2, 3, 4]);
        songs.add(s);
      }
      library.setSongsForTesting(songs);
      library.debugMarkFilesOnDisk(songs.map((s) => s.id));
      final pl = await library.createPlaylist('Mix');
      for (final s in songs) {
        await library.addSongToPlaylist(pl.id, s.id);
      }

      final engine = _FakePlayer();
      final player = PlayerService(
        library,
        identity: identity,
        player: engine,
      );
      addTearDown(player.dispose);
      await player.setLoudnessNormalization(false);

      final controller = AppController(
        identity: identity,
        library: library,
        player: player,
        youtube: YoutubeService(),
      );

      final updatedPl = library.findPlaylist(pl.id)!;
      await controller.playPlaylist(
        updatedPl,
        shuffle: true,
        random: _FixedRandom(2),
      );
      expect(player.shuffle, isTrue);
      expect(player.currentSong?.id, 'p_2');
      expect(player.queueIndex, 2);
      expect(player.queueSourceId, 'playlist:${pl.id}');

      await controller.playPlaylist(updatedPl);
      expect(player.currentSong?.id, 'p_0');
      expect(player.queueIndex, 0);
    });
  });

  group('Fix 6: Desktop NowPlayingPanel Lyrics Options', () {
    for (final size in const [Size(1280, 720), Size(1440, 900)]) {
      testWidgets('Lyrics tab exposes Options button and opens sheet at $size',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final identity = IdentityService(prefs);
          final library = LibraryService();
          final song = _localSong('lyr1', 'Lyric Song', durationMs: 180000);
          library.setSongsForTesting([song]);
          LyricsService.setLyricsForTesting(
            song.id,
            '[00:05.00]Placeholder line one\n[00:10.00]Placeholder line two',
          );

          final history = HistoryService(prefs);
          final player = PlayerService(
            library,
            identity: identity,
            history: history,
            player: _FakePlayer(),
          );
          addTearDown(player.dispose);
          player.updateQueue([song]);
          player.currentSong = song;

          final controller = AppController(
            identity: identity,
            library: library,
            player: player,
            youtube: YoutubeService(),
            history: history,
          );

          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<AppController>.value(value: controller),
                ChangeNotifierProvider<PlayerService>.value(value: player),
                ChangeNotifierProvider<IdentityService>.value(value: identity),
                ChangeNotifierProvider<LibraryService>.value(value: library),
                ChangeNotifierProvider<HistoryService>.value(value: history),
                ChangeNotifierProvider<PlayerTheme>.value(
                  value: PlayerTheme(player),
                ),
              ],
              child: MaterialApp(
                theme: ThemeData.dark(),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: NowPlayingPanel.expandedPaneWidth,
                      height: size.height,
                      child: NowPlayingPanel(
                        onCollapse: () {},
                        onOpenTheater: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));

          expect(
            find.byKey(const ValueKey('pane_lyrics_options')),
            findsNothing,
          );

          await tester.tap(find.text('Lyrics'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull);

          final optionsBtn = find.byKey(const ValueKey('pane_lyrics_options'));
          expect(optionsBtn, findsOneWidget);

          await tester.tap(optionsBtn);
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Lyric timing'), findsOneWidget);
          expect(tester.takeException(), isNull);

          await tester.tapAt(const Offset(10, 10));
          await tester.pump(const Duration(milliseconds: 300));

          await tester.tap(find.text('Up next'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.byKey(const ValueKey('pane_lyrics_options')),
            findsNothing,
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });
}
