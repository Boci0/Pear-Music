import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/song.dart';
import 'artwork_palette.dart';
import 'playback_actions.dart';
import 'player_service.dart';

/// Bridges playback into the Windows System Media Transport Controls: the
/// taskbar thumbnail buttons and the volume flyout media panel. This is the
/// desktop counterpart of the Android media notification, so both platforms
/// show what is playing where the operating system expects it.
class MediaSession {
  MediaSession._();

  static const MethodChannel _channel = MethodChannel('peerm/media_session');
  static bool _initialized = false;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Wires the media session channel. Safe to call more than once.
  static void init(PlayerService player) {
    if (_initialized || !_supported) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'buttonPressed':
          switch (call.arguments) {
            case 'play':
              await player.resume();
            case 'pause':
              await player.pause();
            case 'next':
              PlaybackActions.next(player);
            case 'previous':
              PlaybackActions.previous(player);
          }
        case 'seekTo':
          final ms = call.arguments;
          if (ms is int && ms >= 0) {
            await player.seek(Duration(milliseconds: ms));
          }
      }
      return null;
    });

    String? lastSongId;
    String? lastStatus;

    Future<void> pushTimeline() async {
      await _invoke('setTimeline', {
        'positionMs': (player.position ?? Duration.zero).inMilliseconds,
        'endMs': (player.duration ?? Duration.zero).inMilliseconds,
      });
    }

    // Loads the cover off the UI thread (large local covers decode in an
    // isolate; streamed songs download theirs) and sends it once ready. An
    // empty list clears the thumbnail, so a song without a cover never shows
    // the previous song's art.
    Future<void> pushArtwork(Song song) async {
      final art = song.artwork;
      Uint8List? bytes;
      if (art != null && art.startsWith('http')) {
        bytes = await ArtworkPalette.networkBytes(art);
      } else {
        bytes = await ArtworkPalette.bytesAsync(song);
      }
      // The user may have skipped on while the cover loaded.
      if (song.id != lastSongId) return;
      if (bytes == null || bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
        await _invoke('setArtwork', Uint8List(0));
      } else {
        await _invoke('setArtwork', bytes);
      }
    }

    Future<void> pushState() async {
      final song = player.currentSong;

      if (song?.id != lastSongId) {
        lastSongId = song?.id;
        if (song == null) {
          lastStatus = 'stopped';
          await _invoke('setEnabled', false);
          return;
        }
        await _invoke('setEnabled', true);
        await _invoke('setMetadata', {
          'title': song.title,
          'artist': song.sourceDeviceId == 'stream'
              ? 'Pear Radio'
              : song.sourceDeviceId != null
              ? 'Shared Library'
              : 'Local Library',
        });
        unawaited(pushArtwork(song));
      }

      final status = song == null
          ? 'stopped'
          : player.playing
          ? 'playing'
          : 'paused';
      if (status != lastStatus) {
        lastStatus = status;
        await _invoke('setPlaybackState', status);
      }
      await pushTimeline();
    }

    player.addListener(() {
      unawaited(pushState());
    });

    // Keep the taskbar timeline fresh while music runs; the metadata and state
    // listeners above only fire on actual changes.
    Timer.periodic(const Duration(seconds: 5), (_) {
      if (player.playing) {
        unawaited(pushTimeline());
      }
    });

    unawaited(pushState());
  }

  static Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<Object?>(method, arguments);
    } catch (_) {
      // Channel missing (tests, other platforms): ignore.
    }
  }
}
