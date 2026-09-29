import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/services/library_service.dart';

Map<String, dynamic> _songJson(String id) => {
      'id': id,
      'title': 'Song $id',
      'fileName': '$id.mp3',
      'size': 4,
      'checksum': 'sum_$id',
      'addedAt': DateTime(2026, 9, 29).toIso8601String(),
    };

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('peerm-library-persist');
    Directory(p.join(tempDir.path, 'library')).createSync(recursive: true);
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  void writeAudio(String id) =>
      File(p.join(tempDir.path, 'library', '$id.mp3')).writeAsBytesSync([1, 2, 3, 4]);

  test('an unreadable index is kept aside instead of being overwritten',
      () async {
    final index = File(p.join(tempDir.path, 'index.json'))
      ..writeAsStringSync('[{"id": "a", "title": "trunc');

    final lib = LibraryService()..debugBaseDirectory = tempDir;
    await lib.init();

    expect(lib.songs, isEmpty);
    final kept = File('${index.path}.corrupt');
    expect(kept.existsSync(), isTrue);
    expect(kept.readAsStringSync(), '[{"id": "a", "title": "trunc');
  });

  test('one malformed entry does not cost the rest of the library', () async {
    writeAudio('a');
    writeAudio('b');
    File(p.join(tempDir.path, 'index.json')).writeAsStringSync(jsonEncode([
      _songJson('a'),
      {'id': 'broken', 'title': 42},
      _songJson('b'),
    ]));

    final lib = LibraryService()..debugBaseDirectory = tempDir;
    await lib.init();

    expect(lib.songs.map((s) => s.id), ['a', 'b']);
    expect(File(p.join(tempDir.path, 'index.json.corrupt')).existsSync(), isTrue);
  });

  test('songs whose files are gone are still dropped at startup', () async {
    writeAudio('a');
    File(p.join(tempDir.path, 'index.json'))
        .writeAsStringSync(jsonEncode([_songJson('a'), _songJson('gone')]));

    final lib = LibraryService()..debugBaseDirectory = tempDir;
    await lib.init();

    expect(lib.songs.map((s) => s.id), ['a']);
  });
}
