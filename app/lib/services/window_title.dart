import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'player_service.dart';

/// Mirrors the playing song into the Windows window caption the way desktop
/// players do ("Song · Pear Music"), and restores the original title when
/// nothing is playing.
class WindowTitle {
  WindowTitle._();

  static const MethodChannel _channel = MethodChannel('peerm/window_title');

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static String? _last;
  static String _suffix = 'Pear Music';

  /// Watches [player] for song changes. Safe to call on every platform: the
  /// channel is only used on Windows and errors are swallowed.
  static void init(PlayerService player) {
    if (!_supported) return;

    Future<void> update() async {
      final song = player.currentSong;
      final wanted = song == null ? '' : '${song.title} · $_suffix';
      if (wanted == _last) return;
      _last = wanted;
      try {
        if (song == null) {
          await _channel.invokeMethod<void>('resetTitle');
        } else {
          await _channel.invokeMethod<void>('setTitle', wanted);
        }
      } catch (_) {
        // Channel missing (tests, unsupported platforms): ignore.
      }
    }

    // Read the window caption once so the Beta keeps its own name as the
    // suffix ("... · Pear Music (Beta)").
    _channel
        .invokeMethod<String>('getTitle')
        .then((original) {
          final trimmed = original?.trim() ?? '';
          if (trimmed.isNotEmpty) {
            _suffix = trimmed;
            if (player.currentSong != null) {
              _last = null;
              update();
            }
          }
        })
        .catchError((_) {});

    player.addListener(() => update());
    update();
  }
}
