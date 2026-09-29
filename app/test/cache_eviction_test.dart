import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/services/stream_cache_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Directory.systemTemp.createTempSync('peerm_eviction_');
  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => sandbox.path);
  });
  tearDownAll(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a full cache evicts the song played longest ago, not the oldest download',
      () async {
    final dir = await StreamCacheManager.getCacheDirectory();
    final start = DateTime.now().subtract(const Duration(days: 30));
    final files = <File>[];
    // One more track than the cache keeps, downloaded a minute apart.
    for (var i = 0; i <= StreamCacheManager.maxTrackCount; i++) {
      final id = 'vid${i.toString().padLeft(8, '0')}';
      final f = File(p.join(dir.path, '$id.m4a'))..writeAsBytesSync([1, 2, 3]);
      f.setLastModifiedSync(start.add(Duration(minutes: i)));
      files.add(f);
    }

    // The very first download was just played again.
    await StreamCacheManager.markPlayed(files[0]);
    await StreamCacheManager.enforceCacheQuota();

    expect(files[0].existsSync(), isTrue,
        reason: 'a song played just now stays cached');
    expect(files[1].existsSync(), isFalse,
        reason: 'the song played longest ago makes room');
    expect(files.where((f) => f.existsSync()), hasLength(StreamCacheManager.maxTrackCount));
  });

  test('an unplayable cached file is deleted and no longer counted as cached',
      () async {
    final dir = await StreamCacheManager.getCacheDirectory();
    final f = File(p.join(dir.path, 'zzzzzzzzzzz.m4a'))
      ..writeAsBytesSync(List.filled(60000, 1));
    expect(await StreamCacheManager.getCachedFile('zzzzzzzzzzz'), isNotNull);
    expect(StreamCacheManager.isStreamCachedSync('zzzzzzzzzzz'), isTrue);

    await StreamCacheManager.evictUnplayable(f);

    expect(f.existsSync(), isFalse);
    expect(StreamCacheManager.isStreamCachedSync('zzzzzzzzzzz'), isFalse,
        reason: 'so the next song preload fetches it again');
  });

  test('a library file handed to evictUnplayable is left alone', () async {
    final outside = File(p.join(sandbox.path, 'library_song.m4a'))
      ..writeAsBytesSync([1, 2, 3]);
    await StreamCacheManager.evictUnplayable(outside);
    expect(outside.existsSync(), isTrue);
  });
}
