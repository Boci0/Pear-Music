import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/resolved_link_cache.dart';
import 'package:peerm_app/services/stream_cache_manager.dart';

ResolvedStream _link(String id, {int? expireEpochSeconds}) => ResolvedStream(
      url: 'https://rr1---sn-test.googlevideo.com/videoplayback?id=$id'
          '${expireEpochSeconds == null ? '' : '&expire=$expireEpochSeconds'}',
      ext: 'webm',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Directory.systemTemp.createTempSync('peerm_link_cache_');
  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return sandbox.path;
    });
  });
  tearDownAll(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('ResolvedLinkCache', () {
    late DateTime now;
    late ResolvedLinkCache cache;

    setUp(() {
      now = DateTime(2026, 10, 6, 12);
      cache = ResolvedLinkCache(clock: () => now);
    });

    test('hands a link out once', () {
      cache.put('a', _link('a'));
      expect(cache.contains('a'), isTrue);
      expect(cache.take('a')?.url, contains('id=a'));
      expect(cache.take('a'), isNull);
      expect(cache.contains('a'), isFalse);
    });

    test('drops a link after the maximum age', () {
      cache.put('a', _link('a'));
      now = now.add(const Duration(minutes: 19));
      expect(cache.contains('a'), isTrue);
      now = now.add(const Duration(minutes: 2));
      expect(cache.take('a'), isNull);
      expect(cache.length, 0);
    });

    test('stops using a link shortly before its own expiry', () {
      final expiry = now.add(const Duration(minutes: 10));
      cache.put('a', _link('a', expireEpochSeconds: expiry.millisecondsSinceEpoch ~/ 1000));
      now = now.add(const Duration(minutes: 4));
      expect(cache.contains('a'), isTrue);
      now = now.add(const Duration(minutes: 2));
      expect(cache.contains('a'), isFalse);
    });

    test('ignores a link that is already past its expiry margin', () {
      final expiry = now.add(const Duration(minutes: 3));
      cache.put('a', _link('a', expireEpochSeconds: expiry.millisecondsSinceEpoch ~/ 1000));
      expect(cache.length, 0);
    });

    test('keeps only the newest entries', () {
      final small = ResolvedLinkCache(maxEntries: 2, clock: () => now);
      small.put('a', _link('a'));
      small.put('b', _link('b'));
      small.put('c', _link('c'));
      expect(small.contains('a'), isFalse);
      expect(small.contains('b'), isTrue);
      expect(small.contains('c'), isTrue);
    });

    test('a newer link for the same video replaces the old one', () {
      cache.put('a', _link('a'));
      cache.put('a', _link('a2'));
      expect(cache.length, 1);
      expect(cache.take('a')?.url, contains('id=a2'));
    });

    test('reads the expiry from the link', () {
      expect(
        ResolvedLinkCache.linkExpiryOf('https://x/videoplayback?expire=1791301299&ei=1'),
        DateTime.fromMillisecondsSinceEpoch(1791301299 * 1000),
      );
      expect(ResolvedLinkCache.linkExpiryOf('https://x/videoplayback?id=1'), isNull);
      expect(ResolvedLinkCache.linkExpiryOf('not a url at all'), isNull);
    });
  });

  group('StreamCacheManager link prefetch', () {
    tearDown(() {
      StreamCacheManager.linkCache.clear();
      StreamCacheManager.debugEnsureStreamCachedOverride = null;
    });

    test('a play uses a link resolved ahead of it', () async {
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async => null;
      StreamCacheManager.linkCache.put('vid1', _link('vid1'));

      ResolvedStream? received;
      await StreamCacheManager.ensureStreamCached(
        'vid1',
        onStreamUrl: (stream) => received = stream,
      );

      expect(received?.url, contains('id=vid1'));
      // Single use: a second play must not reuse a link that was handed out.
      expect(StreamCacheManager.linkCache.contains('vid1'), isFalse);
    });

    test('a play without a prefetched link gets none from the cache', () async {
      StreamCacheManager.debugEnsureStreamCachedOverride =
          (videoId, {required isPreload}) async => null;
      ResolvedStream? received;
      await StreamCacheManager.ensureStreamCached(
        'vid2',
        onStreamUrl: (stream) => received = stream,
      );
      expect(received, isNull);
    });

    test('prefetch does nothing when switched off', () async {
      StreamCacheManager.setLinkPrefetchEnabledForTesting(false);
      addTearDown(() => StreamCacheManager.setLinkPrefetchEnabledForTesting(null));
      await StreamCacheManager.prefetchLink('vid3');
      expect(StreamCacheManager.linkCache.contains('vid3'), isFalse);
    });
  });
}
