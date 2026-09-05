import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _createSong({
  required String id,
  required String title,
  String? sourceDeviceId,
  String? artwork,
}) {
  return Song(
    id: id,
    title: title,
    fileName: '.mp3',
    size: 5000000,
    checksum: 'chk_',
    sourceDeviceId: sourceDeviceId,
    artwork: artwork,
    addedAt: DateTime(2025, 1, 1),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return Directory.systemTemp.path;
    });
  });

  group('Favorites Persistence & Multi-source Tests', () {
    test('IdentityService saves and reconstitutes favorite online songs', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final identity = IdentityService(prefs);

      final onlineSong = _createSong(
        id: 'stream_vid123',
        title: 'Online Hit Track',
        sourceDeviceId: 'stream',
        artwork: 'https://i.ytimg.com/vi/vid123/hqdefault.jpg',
      );

      // Favorite the online track
      await identity.toggleFavorite(onlineSong.id, song: onlineSong);
      expect(identity.isFavorite('stream_vid123'), isTrue);
      expect(identity.favoriteSongIds, contains('stream_vid123'));
      expect(identity.favoriteOnlineSongs.containsKey('stream_vid123'), isTrue);
      expect(identity.findFavoriteOnlineSong('stream_vid123')?.title, 'Online Hit Track');

      // Create a fresh IdentityService instance reading from the same prefs
      final freshIdentity = IdentityService(prefs);
      expect(freshIdentity.isFavorite('stream_vid123'), isTrue);
      expect(freshIdentity.favoriteOnlineSongs.containsKey('stream_vid123'), isTrue);
      final restored = freshIdentity.findFavoriteOnlineSong('stream_vid123');
      expect(restored, isNotNull);
      expect(restored!.title, 'Online Hit Track');
      expect(restored.artwork, 'https://i.ytimg.com/vi/vid123/hqdefault.jpg');
      expect(restored.sourceDeviceId, 'stream');

      // Un-favorite
      await freshIdentity.toggleFavorite('stream_vid123');
      expect(freshIdentity.isFavorite('stream_vid123'), isFalse);
      expect(freshIdentity.favoriteOnlineSongs.containsKey('stream_vid123'), isFalse);
      expect(freshIdentity.findFavoriteOnlineSong('stream_vid123'), isNull);

      // Verify persisted removal in new instance
      final verifiedIdentity = IdentityService(prefs);
      expect(verifiedIdentity.isFavorite('stream_vid123'), isFalse);
      expect(verifiedIdentity.favoriteOnlineSongs.isEmpty, isTrue);
    });

    test('AppController.favoriteSongs unifies local and online tracks', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final identity = IdentityService(prefs);
      final library = LibraryService();
      final player = PlayerService(library, identity: identity);
      final controller = AppController(
        identity: identity,
        library: library,
        player: player,
        youtube: YoutubeService(),
      );

      final localSong1 = _createSong(id: 'local_1', title: 'Local Song 1');
      final localSong2 = _createSong(id: 'local_2', title: 'Local Song 2');
      library.setSongsForTesting([localSong1, localSong2]);

      final onlineSong = _createSong(
        id: 'stream_abc999',
        title: 'Stream Favorite',
        sourceDeviceId: 'stream',
        artwork: 'https://example.com/art.jpg',
      );

      // Initially no favorites
      expect(controller.favoriteSongs, isEmpty);

      // Favorite local song 1
      await controller.toggleFavorite(localSong1.id, song: localSong1);
      expect(controller.favoriteSongs.length, 1);
      expect(controller.favoriteSongs.first.id, 'local_1');

      // Favorite online song
      await controller.toggleFavorite(onlineSong.id, song: onlineSong);
      expect(controller.favoriteSongs.length, 2);
      final ids = controller.favoriteSongs.map((s) => s.id).toSet();
      expect(ids, containsAll(['local_1', 'stream_abc999']));

      // Test findSongById
      expect(controller.findSongById('local_1')?.title, 'Local Song 1');
      expect(controller.findSongById('stream_abc999')?.title, 'Stream Favorite');
      expect(controller.findSongById('unknown_id'), isNull);

      // Toggle off local song
      await controller.toggleFavorite(localSong1.id);
      expect(controller.favoriteSongs.length, 1);
      expect(controller.favoriteSongs.first.id, 'stream_abc999');

      // Toggle off online song
      await controller.toggleFavorite(onlineSong.id);
      expect(controller.favoriteSongs, isEmpty);
    });
  });
}
