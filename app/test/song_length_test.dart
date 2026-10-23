import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/song_length_reader.dart';

Song _song(String id, {String? source, bool live = false, int? ms}) => Song(
      id: id,
      title: 'Song $id',
      fileName: '$id.mp3',
      size: 4,
      checksum: 'sum_$id',
      sourceDeviceId: source,
      isLive: live,
      durationMs: ms,
      addedAt: DateTime(2026, 10, 1),
    );

void main() {
  test('length label reads like a clock and is null while unknown', () {
    expect(_song('a').durationLabel, isNull);
    expect(_song('a', ms: 222000).durationLabel, '3:42');
    expect(_song('a', ms: 5000).durationLabel, '0:05');
    expect(_song('a', ms: 3725000).durationLabel, '1:02:05');
  });

  test('length survives the index round trip', () {
    final back = Song.fromJson(_song('a', ms: 1234).toJson());
    expect(back.durationMs, 1234);
    expect(Song.fromJson(_song('b').toJson()).durationMs, isNull);
  });

  test('a length is recorded once, never for live songs', () {
    final lib = LibraryService()
      ..setSongsForTesting([_song('a'), _song('live', live: true)]);
    lib.setSongLength('a', const Duration(seconds: 200));
    lib.setSongLength('a', const Duration(seconds: 90));
    lib.setSongLength('live', const Duration(seconds: 90));
    lib.setSongLength('missing', const Duration(seconds: 90));
    expect(lib.findById('a')!.durationMs, 200000);
    expect(lib.findById('a')!.title, 'Song a');
    expect(lib.findById('live')!.durationMs, isNull);
  });

  test('the reader skips known, live, streamed, failed and missing files', () {
    final lib = LibraryService()
      ..setSongsForTesting([
        _song('todo'),
        _song('known', ms: 1000),
        _song('live', live: true),
        _song('stream', source: 'stream'),
        _song('failed'),
      ]);
    // No file is on disk in a test library, so nothing is readable yet.
    expect(SongLengthReader.pending(lib, {}), isEmpty);
    lib.debugMarkFilesOnDisk(lib.songs.map((s) => s.id));
    expect(
      SongLengthReader.pending(lib, {'failed'}).map((s) => s.id),
      ['todo'],
    );
  });
}
