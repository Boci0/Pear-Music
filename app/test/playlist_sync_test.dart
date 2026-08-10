import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/sync_service.dart';

/// A fake [RTCDataChannel] that forwards every message to the channel on the
/// "other side", so two [SyncService]s can exchange real data through the
/// actual text protocol without a network.
class _FakeChannel extends RTCDataChannel {
  _FakeChannel();

  _FakeChannel? otherSide;

  @override
  RTCDataChannelState? get state => RTCDataChannelState.RTCDataChannelOpen;

  @override
  int? get id => 1;

  @override
  String? get label => 'peerm';

  @override
  int? get bufferedAmount => 0;

  @override
  Future<void> send(RTCDataChannelMessage message) async {
    otherSide?.onMessage?.call(message);
  }

  @override
  Future<void> close() async {}
}

void main() {
  late Directory tempDirA;
  late Directory tempDirB;
  late LibraryService libA;
  late LibraryService libB;
  late SyncService syncA;
  late SyncService syncB;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'peerm_device_id': 'device-A',
      'peerm_device_name': 'Device A',
    });
    final idA = IdentityService(await SharedPreferences.getInstance());
    SharedPreferences.setMockInitialValues({
      'peerm_device_id': 'device-B',
      'peerm_device_name': 'Device B',
    });
    final idB = IdentityService(await SharedPreferences.getInstance());

    tempDirA = await Directory.systemTemp.createTemp('peerm-pl-a');
    tempDirB = await Directory.systemTemp.createTemp('peerm-pl-b');
    libA = LibraryService()..debugBaseDirectory = tempDirA;
    libB = LibraryService()..debugBaseDirectory = tempDirB;
    await libA.init();
    await libB.init();

    syncA = SyncService(identity: idA, library: libA);
    syncB = SyncService(identity: idB, library: libB);
  });

  tearDown(() async {
    // Wait for any in-flight protocol handler (playlist merge → _savePlaylists)
    // to finish writing before we delete the temp dirs; then retry the delete
    // because Windows can transiently hold a file handle.
    await syncA.idle;
    await syncB.idle;
    await _deleteQuiet(tempDirA);
    await _deleteQuiet(tempDirB);
  });

  void connect() {
    final chA = _FakeChannel();
    final chB = _FakeChannel();
    chA.otherSide = chB;
    chB.otherSide = chA;
    syncA.attachChannel('device-B', chA);
    syncB.attachChannel('device-A', chB);
  }

  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('Condition not met within $timeout');
  }

  test('create on A syncs the playlist to B', () async {
    connect();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final pl = await libA.createPlaylist('Road Trip');
    syncA.broadcastPlaylistUpsert(pl);

    await waitFor(() => libB.playlists.length == 1);
    expect(libB.playlists.first.name, 'Road Trip');
    expect(libB.playlists.first.id, pl.id);
  });

  test('rename: the newest edit wins on both devices', () async {
    connect();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final pl = await libA.createPlaylist('Mix');
    syncA.broadcastPlaylistUpsert(pl);
    await waitFor(() => libB.playlists.length == 1);

    await libB.renamePlaylist(pl.id, 'Chill Mix');
    syncB.broadcastPlaylistUpsert(libB.findPlaylist(pl.id)!);

    await waitFor(() => libA.playlists.first.name == 'Chill Mix');
    expect(libB.playlists.first.name, 'Chill Mix');
  });

  test('add/remove songs in a playlist sync to the peer', () async {
    connect();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final pl = await libA.createPlaylist('Gym');
    syncA.broadcastPlaylistUpsert(pl);
    await waitFor(() => libB.playlists.length == 1);

    await libA.addSongToPlaylist(pl.id, 'song-1');
    await libA.addSongToPlaylist(pl.id, 'song-2');
    syncA.broadcastPlaylistUpsert(libA.findPlaylist(pl.id)!);
    await waitFor(() => libB.playlists.first.songIds.length == 2);

    await libA.removeSongFromPlaylist(pl.id, 'song-1');
    syncA.broadcastPlaylistUpsert(libA.findPlaylist(pl.id)!);
    await waitFor(() => libB.playlists.first.songIds.length == 1);
    expect(libB.playlists.first.songIds, ['song-2']);
  });

  test('delete while connected removes it on the peer', () async {
    connect();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final pl = await libA.createPlaylist('Temp');
    syncA.broadcastPlaylistUpsert(pl);
    await waitFor(() => libB.playlists.length == 1);

    final at = await libA.deletePlaylist(pl.id);
    expect(at, isNotNull);
    syncA.broadcastPlaylistDelete(pl.id, at!);

    await waitFor(() => libB.playlists.isEmpty);
    expect(libA.playlists, isEmpty);
  });

  test('delete while offline: tombstone reconciles on reconnect, no resurrect',
      () async {
    await libA.createPlaylist('Old');
    await libA.createPlaylist('Keep');
    connect();
    await waitFor(() => libB.playlists.length == 2);

    // A goes "offline" (channels dropped) and deletes 'Old' without
    // broadcasting — B was not reachable.
    syncA.detachChannel('device-B');
    syncB.detachChannel('device-A');
    final oldPl = libA.playlists.firstWhere((p) => p.name == 'Old');
    await libA.deletePlaylist(oldPl.id);

    // Reconnect: A's manifest carries the tombstone; B drops 'Old' and neither
    // side resurrects it (A must not re-add it from B's stale manifest).
    connect();
    await waitFor(() => libB.playlists.length == 1);
    expect(libB.playlists.first.name, 'Keep');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(libA.playlists.length, 1);
    expect(libA.playlists.first.name, 'Keep');
  });

  test('a newer edit beats a stale offline deletion (newest edit wins)',
      () async {
    final pl = await libA.createPlaylist('Keep Me');
    connect();
    await waitFor(() => libB.playlists.length == 1);

    // A deletes while B is offline…
    syncA.detachChannel('device-B');
    syncB.detachChannel('device-A');
    await libA.deletePlaylist(pl.id);

    // …but B edits the playlist AFTER that deletion timestamp.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await libB.renamePlaylist(pl.id, 'Keep Me (edited)');

    connect();
    // B's newer edit must win: the tombstone is older than B's updatedAt.
    await waitFor(() => libA.playlists.length == 1);
    expect(libA.playlists.first.name, 'Keep Me (edited)');
    expect(libB.playlists.first.name, 'Keep Me (edited)');
  });
}

/// Retry a recursive delete (Windows can transiently hold a file handle).
Future<void> _deleteQuiet(Directory dir) async {
  for (var i = 0; i < 5; i++) {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
