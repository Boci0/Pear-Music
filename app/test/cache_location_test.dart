import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/services/stream_cache_manager.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('peerm_cache_location_');
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Directory old() => Directory(p.join(root.path, 'temp', 'peerm_radio_cache'));
  Directory fresh() =>
      Directory(p.join(root.path, 'appcache', 'peerm_radio_cache'));

  test('moves the cached tracks to the new folder', () async {
    old().createSync(recursive: true);
    File(p.join(old().path, 'abc.webm')).writeAsStringSync('audio');
    Directory(p.join(old().path, '.ytdlp_cache')).createSync();

    await StreamCacheManager.adoptCacheFrom(old(), fresh());

    expect(File(p.join(fresh().path, 'abc.webm')).readAsStringSync(), 'audio');
    expect(Directory(p.join(fresh().path, '.ytdlp_cache')).existsSync(), isTrue);
    expect(old().existsSync(), isFalse);
  });

  test('leaves an existing new folder untouched', () async {
    old().createSync(recursive: true);
    File(p.join(old().path, 'old.webm')).writeAsStringSync('old');
    fresh().createSync(recursive: true);
    File(p.join(fresh().path, 'new.webm')).writeAsStringSync('new');

    await StreamCacheManager.adoptCacheFrom(old(), fresh());

    expect(File(p.join(fresh().path, 'new.webm')).existsSync(), isTrue);
    expect(File(p.join(fresh().path, 'old.webm')).existsSync(), isFalse);
    expect(File(p.join(old().path, 'old.webm')).existsSync(), isTrue);
  });

  test('does nothing when there is no old folder', () async {
    await StreamCacheManager.adoptCacheFrom(old(), fresh());
    expect(fresh().existsSync(), isFalse);
  });

  test('does nothing when both are the same folder', () async {
    old().createSync(recursive: true);
    File(p.join(old().path, 'abc.webm')).writeAsStringSync('audio');

    await StreamCacheManager.adoptCacheFrom(old(), old());

    expect(File(p.join(old().path, 'abc.webm')).existsSync(), isTrue);
  });
}
