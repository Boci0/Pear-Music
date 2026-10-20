import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/app_update_manifest.dart';
import 'package:peerm_app/services/debug_log.dart';
import 'package:peerm_app/services/library_profile.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/lyrics_service.dart';
import 'package:peerm_app/services/playlist_file.dart';
import 'package:peerm_app/services/recommendation_service.dart';
import 'package:peerm_app/services/update_service.dart';

Song _song({
  required String id,
  required String title,
  String fileName = 'song.mp3',
  int size = 4,
  String checksum = 'sum',
  String? sourceDeviceId,
}) =>
    Song(
      id: id,
      title: title,
      fileName: fileName,
      size: size,
      checksum: checksum,
      sourceDeviceId: sourceDeviceId,
      addedAt: DateTime(2026, 9, 29),
    );

Map<String, dynamic> _legacySongJson(String id, String fileName) => {
      'id': id,
      'title': 'Song $id',
      'fileName': fileName,
      'size': 4,
      'addedAt': DateTime(2026, 9, 29).toIso8601String(),
    };

Future<void> _waitFor(bool Function() condition, String label) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('timed out waiting for $label');
}

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });
  return dir;
}

void main() {
  group('BUS-01 playlist load tolerance', () {
    test('one malformed playlist entry keeps the readable playlists', () async {
      final tempDir = await _tempDir('peerm-playlists-bad');
      final file = File(p.join(tempDir.path, 'playlists.json'));
      await file.writeAsString(jsonEncode({
        'playlists': [
          {
            'id': 'good',
            'name': 'Good',
            'songIds': ['a'],
            'createdAt': '2026-09-29T00:00:00.000',
            'updatedAt': '2026-09-29T00:00:00.000',
          },
          {'id': 'bad', 'name': null, 'songIds': <String>[]},
          {
            'id': 'good2',
            'name': 'Good 2',
            'songIds': <String>[],
            'createdAt': '2026-09-29T00:00:00.000',
          },
        ],
        'deleted': {'gone': '2026-09-30T00:00:00.000'},
      }));

      final lib = LibraryService()..debugBaseDirectory = tempDir;
      await lib.init();

      expect(lib.playlists.map((pl) => pl.id), ['good', 'good2']);
      expect(lib.deletedPlaylistsAt['gone'], isNotNull);
      expect(File('${file.path}.corrupt').existsSync(), isTrue);

      // The healed file is readable again and keeps what was recovered.
      final reloaded = LibraryService()..debugBaseDirectory = tempDir;
      await reloaded.init();
      expect(reloaded.playlists.map((pl) => pl.id), ['good', 'good2']);
      expect(reloaded.deletedPlaylistsAt['gone'], isNotNull);
    });

    test('a playlists section that is not a list is broken, not empty',
        () async {
      final tempDir = await _tempDir('peerm-playlists-shape');
      final file = File(p.join(tempDir.path, 'playlists.json'));
      await file.writeAsString(jsonEncode({
        'playlists': 'nope',
        'deleted': <String, String>{},
      }));

      final lib = LibraryService()..debugBaseDirectory = tempDir;
      await lib.init();

      expect(lib.playlists, isEmpty);
      expect(File('${file.path}.corrupt').existsSync(), isTrue);
      final healed = jsonDecode(await file.readAsString());
      expect(healed, isA<Map<String, dynamic>>());
      expect((healed as Map<String, dynamic>)['playlists'], isA<List<dynamic>>());
    });
  });

  group('BUS-02 removeSong', () {
    test(
      'removeSong still saves and strips playlists when the file is locked',
      () async {
        final tempDir = await _tempDir('peerm-remove-locked');
        File? locked;
        addTearDown(() async {
          final file = locked;
          try {
            if (file != null && file.existsSync()) {
              await Process.run('attrib', ['-R', file.path]);
            }
          } catch (_) {}
        });

        final src = File(p.join(tempDir.path, 'src.mp3'))
          ..writeAsBytesSync(const [1, 2, 3, 4]);
        final lib = LibraryService()..debugBaseDirectory = tempDir;
        await lib.init();
        final song = (await lib.addLocalFiles([src])).single;
        final pl = await lib.createPlaylist('Keep');
        await lib.addSongToPlaylist(pl.id, song.id);

        final lockedFile = lib.songFile(song);
        locked = lockedFile;
        final attrib = await Process.run('attrib', ['+R', lockedFile.path]);
        expect(attrib.exitCode, 0, reason: 'could not make the file read-only');

        // Must not throw even though the delete is denied, and must still
        // persist the removal and strip the playlist.
        await lib.removeSong(song.id);
        expect(lib.findById(song.id), isNull);
        expect(lib.findPlaylist(pl.id)!.songIds, isEmpty);

        final reloaded = LibraryService()..debugBaseDirectory = tempDir;
        await reloaded.init();
        expect(reloaded.findById(song.id), isNull);
        expect(reloaded.findPlaylist(pl.id)!.songIds, isEmpty);
      },
      skip: Platform.isWindows
          ? false
          : 'Windows only: a read-only file cannot be deleted',
    );
  });

  group('BUS-03 DebugLog buffering', () {
    test('lines written during init are flushed to the file', () async {
      final tempDir = await _tempDir('peerm-debuglog');
      DebugLog.resetForTesting();
      DebugLog.debugBaseDirectory = tempDir;
      addTearDown(() {
        DebugLog.resetForTesting();
        DebugLog.debugBaseDirectory = null;
      });

      DebugLog.write('[audit] first line before init', echo: false);
      DebugLog.write('[audit] second line before init', echo: false);

      final file = File(p.join(tempDir.path, 'peerm_debug.log'));
      await _waitFor(
        () =>
            file.existsSync() &&
            file.readAsStringSync().contains('[audit] second line before init'),
        'the buffered log lines',
      );
      final text = file.readAsStringSync();
      expect(text, contains('[audit] first line before init'));
      expect(DebugLog.file, isNotNull);
    });
  });

  group('BUS-05 empty checksums', () {
    test('entries without a checksum are not deduplicated', () async {
      final tempDir = await _tempDir('peerm-empty-checksum');
      final libraryDir = Directory(p.join(tempDir.path, 'library'))
        ..createSync(recursive: true);
      File(p.join(libraryDir.path, 'one.mp3')).writeAsBytesSync([1, 2, 3, 4]);
      File(p.join(libraryDir.path, 'two.mp3')).writeAsBytesSync([5, 6, 7, 8]);
      await File(p.join(tempDir.path, 'index.json')).writeAsString(jsonEncode([
        _legacySongJson('one', 'one.mp3'),
        _legacySongJson('two', 'two.mp3'),
      ]));

      final lib = LibraryService()..debugBaseDirectory = tempDir;
      await lib.init();

      expect(lib.songs.map((s) => s.id), ['one', 'two']);
      expect(lib.hasChecksum(''), isFalse);
      expect(lib.findByChecksum(''), isNull);
    });
  });

  group('BUS-06 index shape', () {
    test('a non-list index is kept aside before it can be overwritten',
        () async {
      final tempDir = await _tempDir('peerm-index-shape');
      final index = File(p.join(tempDir.path, 'index.json'));
      await index.writeAsString('{"songs": []}');

      final lib = LibraryService()..debugBaseDirectory = tempDir;
      await lib.init();

      expect(lib.songs, isEmpty);
      final kept = File('${index.path}.corrupt');
      expect(kept.existsSync(), isTrue);
      expect(await kept.readAsString(), '{"songs": []}');
    });
  });

  group('BUS-07 version compare', () {
    test('a four-part release version is newer than its three-part prefix', () {
      const fourPart = AppUpdateManifest(
        version: '4.3.5.1',
        notes: 'notes',
        page: 'https://example.com/releases',
        assets: <String, AppUpdateAsset>{},
      );
      expect(
        UpdateService.buildInfoFromManifest(
          fourPart,
          currentVersion: '4.3.5',
        ).hasUpdate,
        isTrue,
      );
      expect(
        UpdateService.buildInfoFromManifest(
          fourPart,
          currentVersion: '4.3.5.2',
        ).hasUpdate,
        isFalse,
      );
    });
  });

  group('BUS-08 manifest assets', () {
    test('one bad urls field only drops that asset', () {
      final pair = ed.generateKey();
      final keys = [base64.encode(pair.publicKey.bytes)];
      final body = {
        'schema': 1,
        'kind': 'app-update',
        'version': '4.3.5',
        'notes': 'Fixes things',
        'page': 'https://github.com/Boci0/Pear-Music/releases/tag/v4.3.5',
        'assets': {
          'good.zip': {
            'sha256': 'a' * 64,
            'size': 10,
            'urls': ['https://host.example/good.zip'],
          },
          'bad.zip': {
            'sha256': 'b' * 64,
            'size': 10,
            'urls': 'not-a-list',
          },
        },
      };
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
      final manifest = AppUpdateManifest.parseVerified(
        bytes,
        ed.sign(pair.privateKey, bytes),
        publicKeysBase64: keys,
      );

      expect(manifest, isNotNull);
      expect(manifest!.assets.keys, ['good.zip']);
      expect(manifest.assets['good.zip']!.urls,
          ['https://host.example/good.zip']);
    });
  });

  group('BUS-12 safeFileName', () {
    test('reserved device names and trailing dots are escaped', () {
      expect(PlaylistFile.safeFileName('CON'), '_CON.m3u8');
      expect(PlaylistFile.safeFileName('aux'), '_aux.m3u8');
      expect(PlaylistFile.safeFileName('COM1'), '_COM1.m3u8');
      expect(PlaylistFile.safeFileName('LPT9'), '_LPT9.m3u8');
      expect(PlaylistFile.safeFileName('NUL'), '_NUL.m3u8');
      expect(PlaylistFile.safeFileName('mix.'), 'mix.m3u8');
      expect(PlaylistFile.safeFileName('mix... '), 'mix.m3u8');
      expect(PlaylistFile.safeFileName('   '), 'playlist.m3u8');
      expect(PlaylistFile.safeFileName('My: List'), 'My_ List.m3u8');
    });
  });

  group('BUS-13 profile titles', () {
    test('newlines in titles and credits are removed on export', () {
      final content = LibraryProfile.build(
        [
          _song(
            id: 'profile-song',
            title: 'Line one\nLine two',
            fileName: 'Line one [dQw4w9WgXcQ].m4a',
          ),
        ],
        onlineFavorites: const [
          ProfileOnlineFavorite(
            videoId: 'abcdefghijk',
            title: 'Title\nSplit',
            artist: 'Artist\nSplit',
          ),
        ],
      );

      expect(content, isNotNull);
      final lines = content!.split('\n');
      expect(lines, contains('#EXTINF:-1,Line one Line two'));
      expect(lines, contains('#EXTINF:-1,Title Split'));
      expect(lines, contains('#PEARMUSIC-ARTIST Artist Split'));

      final entries = LibraryProfile.parse(content);
      expect(entries.single.videoId, 'dQw4w9WgXcQ');
      expect(entries.single.title, 'Line one Line two');
      final online = LibraryProfile.parseOnlineFavorites(content);
      expect(online.single.title, 'Title Split');
      expect(online.single.artist, 'Artist Split');
    });
  });

  group('INE-02 bulk removal', () {
    test('removeAllFromSource clears a peer batch and persists in one pass',
        () async {
      final tempDir = await _tempDir('peerm-remove-source');
      final lib = LibraryService()..debugBaseDirectory = tempDir;
      await lib.init();
      final plA = await lib.createPlaylist('A');
      final plB = await lib.createPlaylist('B');
      final ids = <String>[];
      for (var i = 0; i < 12; i++) {
        final id = 'peer-$i';
        lib.incomingFile(id).writeAsBytesSync(List<int>.filled(16, i));
        await lib.addReceivedSong(
          id: id,
          title: 'Peer $i',
          fileName: '$id.mp3',
          size: 16,
          checksum: 'cs-$i',
          sourceDeviceId: 'peer-X',
        );
        ids.add(id);
      }
      await lib.setPlaylistSongIds(plA.id, ids);
      await lib.addSongToPlaylist(plB.id, ids.first);

      expect(await lib.removeAllFromSource('peer-X'), ids.length);
      expect(lib.songs, isEmpty);
      expect(lib.findPlaylist(plA.id)!.songIds, isEmpty);
      expect(lib.findPlaylist(plB.id)!.songIds, isEmpty);

      final reloaded = LibraryService()..debugBaseDirectory = tempDir;
      await reloaded.init();
      expect(reloaded.songs, isEmpty);
      expect(reloaded.findPlaylist(plA.id)!.songIds, isEmpty);
      expect(reloaded.findPlaylist(plB.id)!.songIds, isEmpty);
    });

    test('startup pruning of a missing file also strips it from playlists',
        () async {
      final tempDir = await _tempDir('peerm-prune-strip');
      final srcA = File(p.join(tempDir.path, 'a.mp3'))
        ..writeAsBytesSync([1, 2, 3, 4]);
      final srcB = File(p.join(tempDir.path, 'b.mp3'))
        ..writeAsBytesSync([5, 6, 7, 8]);
      final lib = LibraryService()..debugBaseDirectory = tempDir;
      await lib.init();
      final added = await lib.addLocalFiles([srcA, srcB]);
      final gone = added[0];
      final kept = added[1];
      final pl = await lib.createPlaylist('Mix');
      await lib.setPlaylistSongIds(pl.id, [gone.id, kept.id]);
      await lib.songFile(gone).delete();

      final reloaded = LibraryService()..debugBaseDirectory = tempDir;
      await reloaded.init();
      expect(reloaded.songs.map((s) => s.id), [kept.id]);
      expect(reloaded.findPlaylist(pl.id)!.songIds, [kept.id]);

      // Init saves the pruned index and playlists without awaiting them.
      await _waitFor(
        () {
          final playlists = File(p.join(tempDir.path, 'playlists.json'));
          if (!playlists.existsSync()) return false;
          return playlists.readAsStringSync().contains(kept.id) &&
              !playlists.readAsStringSync().contains(gone.id);
        },
        'the pruned playlists file',
      );
      final again = LibraryService()..debugBaseDirectory = tempDir;
      await again.init();
      expect(again.findPlaylist(pl.id)!.songIds, [kept.id]);
    });
  });

  group('INE-04 offline recommendations', () {
    test('ties resolve deterministically and only the best ten are returned',
        () {
      final seed = _song(id: 'seed', title: 'Queen - Bohemian Rhapsody');
      final library = <Song>[
        _song(id: 'track-b', title: 'Queen - Track B'),
        _song(id: 'track-a', title: 'Queen - Track A'),
        _song(id: 'beethoven', title: 'Beethoven - Symphony'),
        for (var i = 0; i < 10; i++)
          _song(
            id: 'q$i',
            title: 'Queen - Song ${i.toString().padLeft(2, '0')}',
          ),
      ];

      final first = RecommendationService.getOfflineRecommendations(seed, library);
      expect(first, hasLength(10));
      expect(first.map((s) => s.id).toList(), [
        'q0', 'q1', 'q2', 'q3', 'q4', 'q5', 'q6', 'q7', 'q8', 'q9',
      ]);

      // The input order must not change the result.
      final shuffled = <Song>[...library]..shuffle();
      final second =
          RecommendationService.getOfflineRecommendations(seed, shuffled);
      expect(
        second.map((s) => s.id).toList(),
        first.map((s) => s.id).toList(),
      );

      final excluded = RecommendationService.getOfflineRecommendations(
        seed,
        library,
        excludeSongIds: {'q0'},
      );
      expect(excluded.first.id, 'q1');
    });
  });

  group('BUS-04 atomic lyric writes', () {
    test('companion .lrc edits are written atomically and land intact',
        () async {
      final tempDir = await _tempDir('peerm-lyrics-atomic');
      final audioPath = p.join(tempDir.path, 'song.mp3');
      final lrc = File(p.join(tempDir.path, 'song.lrc'));
      await File(audioPath).writeAsBytes([1, 2, 3]);
      await lrc.writeAsString('[00:01.00] Old line\n');
      final song = _song(
        id: 'atomic-song',
        title: 'Atomic',
        fileName: 'song.mp3',
        checksum: 'atomic-sum',
      );
      const candidate = LrcCandidate(
        id: 1,
        trackName: 'Atomic',
        artistName: 'Artist',
        albumName: '',
        duration: 60,
        hasSyncedLyrics: true,
        syncedLyrics: '[00:01.00] New line\n[00:05.00] Second line',
      );

      LyricsService.clearMemoryCache();
      addTearDown(LyricsService.clearMemoryCache);

      await LyricsService.applyCandidate(
        song,
        candidate,
        localAudioPath: audioPath,
      );
      // A temp file must never be left behind next to the lyrics.
      expect(File('${lrc.path}.tmp').existsSync(), isFalse);
      expect(await lrc.readAsString(), candidate.lyricsContent);

      await LyricsService.setOffset(song, 250, localAudioPath: audioPath);
      expect(File('${lrc.path}.tmp').existsSync(), isFalse);
      expect(await lrc.readAsString(), startsWith('[offset: 250]'));
    });
  });
}
