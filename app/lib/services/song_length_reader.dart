import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../models/song.dart';
import 'library_service.dart';

/// Fills in play lengths for library files that have none yet (Windows), so
/// the length column is complete before every song has been played.
///
/// One muted media_kit player with audio and video decoding off opens each
/// file in turn without playing it; mpv reads the length from the container.
/// Runs a few seconds after the library settles, one file at a time.
class SongLengthReader {
  SongLengthReader._(this._library);

  final LibraryService _library;
  final Set<String> _failed = {};
  Timer? _debounce;
  bool _running = false;

  /// Starts watching [library] for songs without a length. Windows only:
  /// starting media_kit on Android has frozen the app before (see
  /// VideoService), and the phone learns lengths as songs play.
  static void attach(LibraryService library) {
    if (kIsWeb || !Platform.isWindows) return;
    final reader = SongLengthReader._(library);
    library.addListener(reader._schedule);
    reader._schedule();
  }

  /// Songs whose length can be read from a file on disk.
  @visibleForTesting
  static List<Song> pending(LibraryService library, Set<String> skip) => [
        for (final s in library.songs)
          if (s.durationMs == null &&
              !s.isLive &&
              s.sourceDeviceId != 'stream' &&
              !skip.contains(s.id) &&
              library.hasSongFile(s))
            s,
      ];

  void _schedule() {
    if (_running) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 5), _run);
  }

  Future<void> _run() async {
    if (_running) return;
    var todo = pending(_library, _failed);
    if (todo.isEmpty) return;
    _running = true;
    Player? player;
    try {
      MediaKit.ensureInitialized();
      player = Player(
        configuration: const PlayerConfiguration(
          title: 'Pear Music lengths',
          muted: true,
          bufferSize: 1024 * 1024,
        ),
      );
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('aid', 'no');
        await platform.setProperty('vid', 'no');
        await platform.setProperty('cache-on-disk', 'no');
      }
      // Songs added while reading are picked up by the next pass.
      while (todo.isNotEmpty) {
        for (final song in todo) {
          final length = await _read(player, _library.songFile(song).path);
          if (length == null) {
            _failed.add(song.id);
          } else {
            _library.setSongLength(song.id, length);
          }
        }
        todo = pending(_library, _failed);
      }
    } catch (e) {
      debugPrint('[lengths] reader stopped: $e');
    } finally {
      await player?.dispose();
      _running = false;
    }
  }

  static Future<Duration?> _read(Player player, String path) async {
    try {
      final next = player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 5));
      await player.open(Media(path), play: false);
      final length = await next;
      await player.stop();
      return length;
    } catch (_) {
      return null;
    }
  }
}
