import 'package:flutter/services.dart';

import 'playback_actions.dart';
import 'player_service.dart';

/// Bridges hardware media keys into playback.
///
/// Windows delivers media keys as WM_APPCOMMAND, which the Flutter engine has
/// no use for, so the native runner forwards the transport commands over the
/// `peerm/media_keys` channel. On Android the system media session already
/// handles them through audio_service, so this channel simply stays quiet.
/// Inert when nothing is loaded, like every other playback entry point.
class MediaKeys {
  MediaKeys._();

  static const MethodChannel _channel = MethodChannel('peerm/media_keys');
  static bool _initialized = false;

  /// Wires the media key channel. Safe to call more than once.
  static void init(PlayerService player) {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'playPause':
          PlaybackActions.toggle(player);
        case 'next':
          PlaybackActions.next(player);
        case 'previous':
          PlaybackActions.previous(player);
      }
      return null;
    });
  }
}
