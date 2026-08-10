import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:peerm_app/services/library_service.dart';

void main() {
  late Directory tempDir;
  late LibraryService lib;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('peerm-playlists-test');
    lib = LibraryService()..debugBaseDirectory = tempDir;
    await lib.init();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  /// Helper: add a fake "audio" file to the library and return its song.
  Future<dynamic> addSong(String name, {int seed = 5}) async {
    final f = File('${tempDir.path}/$name');
    f.writeAsBytesSync(List<int>.generate(10_000, (i) => (i * seed) % 256));
    final added = await lib.addLocalFiles([f]);
    return added.first;
  }

  test('create / find / list playlists', () async {
    expect(lib.playlists, isEmpty);
    final pl = await lib.createPlaylist('Road trip');
    expect(pl.name, 'Road trip');
    expect(lib.findPlaylist(pl.id)?.id, pl.id);
    expect(lib.playlists.length, 1);
  });

  test('add songs to a playlist with dedup', () async {
    final songA = await addSong('a.mp3', seed: 1);
    final songB = await addSong('b.mp3', seed: 2);
    final pl = await lib.createPlaylist('Mixed');

    expect(await lib.addSongToPlaylist(pl.id, songA.id), isTrue);
    expect(await lib.addSongToPlaylist(pl.id, songB.id), isTrue);
    // Adding the same song again is a no-op.
    expect(await lib.addSongToPlaylist(pl.id, songA.id), isFalse);

    final updated = lib.findPlaylist(pl.id)!;
    expect(updated.songIds, [songA.id, songB.id]);
  });

  test('remove song from playlist preserves order', () async {
    final a = await addSong('a.mp3', seed: 1);
    final b = await addSong('b.mp3', seed: 2);
    final c = await addSong('c.mp3', seed: 3);
    final pl = await lib.createPlaylist('Ordered');
    await lib.addSongToPlaylist(pl.id, a.id);
    await lib.addSongToPlaylist(pl.id, b.id);
    await lib.addSongToPlaylist(pl.id, c.id);

    await lib.removeSongFromPlaylist(pl.id, b.id);
    expect(lib.findPlaylist(pl.id)!.songIds, [a.id, c.id]);
  });

  test('reorder playlist (setPlaylistSongIds)', () async {
    final a = await addSong('a.mp3', seed: 1);
    final b = await addSong('b.mp3', seed: 2);
    final pl = await lib.createPlaylist('Reorder');
    await lib.addSongToPlaylist(pl.id, a.id);
    await lib.addSongToPlaylist(pl.id, b.id);

    await lib.setPlaylistSongIds(pl.id, [b.id, a.id]);
    expect(lib.findPlaylist(pl.id)!.songIds, [b.id, a.id]);
  });

  test('rename + delete playlist', () async {
    final pl = await lib.createPlaylist('Old name');
    await lib.renamePlaylist(pl.id, 'New name');
    expect(lib.findPlaylist(pl.id)!.name, 'New name');

    await lib.deletePlaylist(pl.id);
    expect(lib.findPlaylist(pl.id), isNull);
    expect(lib.playlists, isEmpty);
  });

  test('playlists persist across re-init', () async {
    final song = await addSong('persist.mp3');
    final pl = await lib.createPlaylist('Persist me');
    await lib.addSongToPlaylist(pl.id, song.id);

    // Re-create the service against the same directory.
    final lib2 = LibraryService()..debugBaseDirectory = tempDir;
    await lib2.init();

    expect(lib2.playlists.length, 1);
    final loaded = lib2.playlists.first;
    expect(loaded.name, 'Persist me');
    expect(loaded.songIds, [song.id]);
  });

  test('removing a song strips it from every playlist', () async {
    final a = await addSong('a.mp3', seed: 1);
    final b = await addSong('b.mp3', seed: 2);
    final pl = await lib.createPlaylist('Cleanup');
    await lib.addSongToPlaylist(pl.id, a.id);
    await lib.addSongToPlaylist(pl.id, b.id);

    await lib.removeSong(a.id);
    expect(lib.findPlaylist(pl.id)!.songIds, [b.id]);

    // removeAllFromSource also strips playlists.
    await lib.removeSong(b.id);
    expect(lib.findPlaylist(pl.id)!.songIds, isEmpty);
  });

  test('removeAllFromSource only removes songs from that source', () async {
    final fromPeer = await addSong('shared.mp3', seed: 7);
    final own = await addSong('own.mp3', seed: 9);
    final pl = await lib.createPlaylist('Mix');
    await lib.addSongToPlaylist(pl.id, fromPeer.id);
    await lib.addSongToPlaylist(pl.id, own.id);

    final removed = await lib.removeAllFromSource('peer-X');
    expect(removed, 0); // shared.mp3 has no sourceDeviceId set here

    // Simulate a peer-sourced song then remove all from that source. Mirrors
    // the real flow: a partial download file is finalized by addReceivedSong.
    lib.incomingFile('shared-from-peer')
        .writeAsBytesSync(List.filled(100, 0));
    await lib.addReceivedSong(
      id: 'shared-from-peer',
      title: 'Shared',
      fileName: 'shared-from-peer.mp3',
      size: 100,
      checksum: 'abc',
      sourceDeviceId: 'peer-X',
    );
    await lib.addSongToPlaylist(pl.id, 'shared-from-peer');
    final removed2 = await lib.removeAllFromSource('peer-X');
    expect(removed2, 1);
    expect(lib.findPlaylist(pl.id)!.songIds, [fromPeer.id, own.id]);
  });
}
