import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/sync_service.dart';

/// A fake [RTCDataChannel] that forwards every message to the channel on the
/// "other side", so two [SyncService]s can exchange real data through the
/// actual binary/text protocol without a network.
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
  late IdentityService idA;
  late IdentityService idB;
  late SyncService syncA;
  late SyncService syncB;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'peerm_device_id': 'device-A',
      'peerm_device_name': 'Device A',
    });
    idA = IdentityService(await SharedPreferences.getInstance());
    SharedPreferences.setMockInitialValues({
      'peerm_device_id': 'device-B',
      'peerm_device_name': 'Device B',
    });
    idB = IdentityService(await SharedPreferences.getInstance());

    tempDirA = await Directory.systemTemp.createTemp('peerm-test-a');
    tempDirB = await Directory.systemTemp.createTemp('peerm-test-b');
    libA = LibraryService()..debugBaseDirectory = tempDirA;
    libB = LibraryService()..debugBaseDirectory = tempDirB;
    await libA.init();
    await libB.init();

    syncA = SyncService(identity: idA, library: libA);
    syncB = SyncService(identity: idB, library: libB);
  });

  tearDown(() async {
    await tempDirA.delete(recursive: true);
    await tempDirB.delete(recursive: true);
  });

  /// Wire two sync services together with fake channels.
  void connect() {
    final chA = _FakeChannel();
    final chB = _FakeChannel();
    chA.otherSide = chB;
    chB.otherSide = chA;
    // From A's perspective the channel belongs to device-B, and vice-versa.
    syncA.attachChannel('device-B', chA);
    syncB.attachChannel('device-A', chB);
  }

  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('Condition not met within $timeout');
  }

  File makeAudio(String name, int size, {int seed = 31}) {
    final f = File('${tempDirA.path}/$name');
    f.writeAsBytesSync(List<int>.generate(size, (i) => (i * seed) % 256));
    return f;
  }

  test('manifest sync: peer pulls songs it is missing on connect', () async {
    await libA.addLocalFiles([makeAudio('song-one.mp3', 300_000)]);
    expect(libA.songs.length, 1);

    connect();

    // B should pull A's song automatically (source = device-A).
    await waitFor(() => libB.songs.length == 1);
    final received = libB.songs.first;
    expect(received.sourceDeviceId, 'device-A');
    expect(received.title, 'song-one');

    // The received bytes match the original file exactly.
    final orig = await libA.songFile(libA.songs.first).readAsBytes();
    final copy = await libB.songFile(received).readAsBytes();
    expect(orig.length, copy.length);
    expect(orig, copy);
    // ...and no duplicate on a second manifest exchange.
    syncB.detachChannel('device-A');
    syncA.detachChannel('device-B');
    connect();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(libB.songs.length, 1);
  });

  test('broadcast: newly added song reaches all connected peers', () async {
    connect();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    await libA.addLocalFiles([makeAudio('fresh-track.mp3', 700_000)]);
    final song = libA.songs.first;
    unawaitedSync(syncA.broadcastSong(song));

    await waitFor(() => libB.songs.length == 1);
    final received = libB.songs.first;
    expect(received.sourceDeviceId, 'device-A');
    expect(received.checksum, song.checksum);
    final copy = await libB.songFile(received).readAsBytes();
    expect(copy.length, 700_000);
  });

  test('dedup: already-shared songs are not duplicated', () async {
    await libA.addLocalFiles([makeAudio('dup.mp3', 120_000)]);
    connect();
    await waitFor(() => libB.songs.length == 1);

    // Re-broadcasting a song the peer already has must not add a duplicate.
    await syncA.broadcastSong(libA.songs.first);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(libB.songs.length, 1);
  });

  test('unpair: removes all songs received from that source', () async {
    await libA.addLocalFiles([makeAudio('a1.mp3', 100_000, seed: 1)]);
    await libA.addLocalFiles([makeAudio('a2.mp3', 100_000, seed: 2)]);
    // B also has its own local song (source = null) that must survive.
    await libB.addLocalFiles([File('${tempDirB.path}/my-own.mp3')]
      ..[0].writeAsBytesSync(List.filled(5000, 7)));
    connect();
    await waitFor(() => libB.songs.length == 3);

    final removed = await libB.removeAllFromSource('device-A');
    expect(removed, 2);
    expect(libB.songs.length, 1);
    expect(libB.songs.first.sourceDeviceId, isNull);

    // Files are gone from disk too.
    final dirB = Directory('${tempDirB.path}/library');
    final files = dirB.listSync().whereType<File>().toList();
    expect(files.length, 1); // only the locally-added song remains
  });

  test('bidirectional: B can share back to A', () async {
    connect();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await libB.addLocalFiles([File('${tempDirB.path}/from-b.mp3')
      ..writeAsBytesSync(List.filled(250_000, 3))]);
    final song = libB.songs.first;
    unawaitedSync(syncB.broadcastSong(song));

    await waitFor(() => libA.songs.length == 1);
    expect(libA.songs.first.sourceDeviceId, 'device-B');
  });

  test('multi-peer: two peers both receive the same requested song', () async {
    SharedPreferences.setMockInitialValues({
      'peerm_device_id': 'device-C',
      'peerm_device_name': 'Device C',
    });
    final idC = IdentityService(await SharedPreferences.getInstance());
    final tempDirC = await Directory.systemTemp.createTemp('peerm-test-c');
    final libC = LibraryService()..debugBaseDirectory = tempDirC;
    await libC.init();
    final syncC = SyncService(identity: idC, library: libC);

    try {
      await libA.addLocalFiles([makeAudio('shared.mp3', 400_000)]);

      // A <-> B
      final chAB = _FakeChannel();
      final chBA = _FakeChannel();
      chAB.otherSide = chBA;
      chBA.otherSide = chAB;
      syncA.attachChannel('device-B', chAB);
      syncB.attachChannel('device-A', chBA);

      // A <-> C (concurrent request for the same missing song)
      final chAC = _FakeChannel();
      final chCA = _FakeChannel();
      chAC.otherSide = chCA;
      chCA.otherSide = chAC;
      syncA.attachChannel('device-C', chAC);
      syncC.attachChannel('device-A', chCA);

      // Both peers must pull the song (guard: send-in-progress is per-peer,
      // so the same song can transfer to two peers at once).
      await waitFor(() => libB.songs.length == 1);
      await waitFor(() => libC.songs.length == 1);
      expect(libB.songs.first.sourceDeviceId, 'device-A');
      expect(libC.songs.first.sourceDeviceId, 'device-A');

      final copyC = await libC.songFile(libC.songs.first).readAsBytes();
      expect(copyC.length, 400_000);
    } finally {
      await tempDirC.delete(recursive: true);
    }
  });

  test('delete: removing the original propagates to shared copies (online)',
      () async {
    await libA.addLocalFiles([makeAudio('gone.mp3', 150_000)]);
    connect();
    await waitFor(() => libB.songs.length == 1);
    expect(libB.songs.first.sourceDeviceId, 'device-A');

    // A removes its original and broadcasts the deletion.
    final song = libA.songs.first;
    await libA.removeSong(song.id);
    syncA.broadcastSongDeleted(song);

    // B must drop its shared copy (file + index entry). Wait on the FILE too,
    // not just the in-memory list: `songs.isEmpty` flips before the async file
    // delete finishes, and tearDown would otherwise race that delete (Windows).
    final dirB = Directory('${tempDirB.path}/library');
    await waitFor(() {
      return libB.songs.isEmpty &&
          dirB.listSync().whereType<File>().isEmpty;
    });
    expect(libB.songs, isEmpty);
    expect(dirB.listSync().whereType<File>().length, 0);
  });

  test('delete: removing a SHARED copy does not delete the original on the peer',
      () async {
    await libA.addLocalFiles([makeAudio('mine.mp3', 90_000)]);
    connect();
    await waitFor(() => libB.songs.length == 1);
    expect(libB.songs.first.sourceDeviceId, 'device-A');

    // B deletes its shared copy and broadcasts — A's original must survive
    // (only shared copies are removed on the receiving side).
    final shared = libB.songs.first;
    await libB.removeSong(shared.id);
    syncB.broadcastSongDeleted(shared);

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(libA.songs.length, 1);
    expect(libA.songs.first.sourceDeviceId, isNull);
    expect(libB.songs, isEmpty);
  });

  test('delete while offline: reconcile on reconnect, no re-download', () async {
    await libA.addLocalFiles([makeAudio('oops.mp3', 120_000)]);
    connect();
    await waitFor(() => libB.songs.length == 1);

    // A goes "offline" (channels dropped), then deletes the original without
    // broadcasting — the peer was not reachable, so the delete never arrived.
    syncA.detachChannel('device-B');
    syncB.detachChannel('device-A');
    final song = libA.songs.first;
    await libA.removeSong(song.id);
    expect(libA.songs, isEmpty);
    expect(libB.songs.length, 1); // stale shared copy still on B

    // Reconnect: manifest exchange must reconcile — A tells B to drop the copy
    // and must NOT request it back (which would leave both sides "Shared").
    connect();
    final dirB = Directory('${tempDirB.path}/library');
    await waitFor(() {
      return libB.songs.isEmpty &&
          dirB.listSync().whereType<File>().isEmpty;
    });
    expect(libA.songs, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(libA.songs, isEmpty);
    expect(libB.songs, isEmpty);
  });

  test('artwork (base64 thumbnail) rides along to the peer', () async {
    // A adds a local song with artwork; B should pull both audio AND artwork.
    final added = await libA.addScrapedFile(
      makeAudio('art.mp3', 60_000),
      title: 'Art Track',
      artwork: 'c29tZS1qcGVn', // arbitrary base64, preserved as-is
    );
    expect(added, isNotNull);

    connect();
    await waitFor(() => libB.songs.length == 1);
    final received = libB.songs.first;
    expect(received.title, 'Art Track');
    expect(received.sourceDeviceId, 'device-A');
    expect(received.artwork, 'c29tZS1qcGVn');
    expect(libA.songs.first.artwork, 'c29tZS1qcGVn');

    // And the audio bytes match.
    final orig = await libA.songFile(libA.songs.first).readAsBytes();
    final copy = await libB.songFile(received).readAsBytes();
    expect(orig, copy);

    // Let the receiver's async finalize (index write) finish before teardown.
    await syncA.idle;
    await syncB.idle;
  });
}

/// Fire-and-forget wrapper so tests read cleanly.
void unawaitedSync(Future<void> future) {
  // ignore: unawaited_futures
  future.then((_) {}, onError: (Object e, StackTrace st) {
    fail('unexpected async error: $e');
  });
}
