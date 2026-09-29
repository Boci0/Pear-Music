import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the display from sleeping while any holder asks for it.
///
/// Holders are the widgets showing something worth watching (the player's
/// lyrics or visualizer). The screen may sleep again as soon as the last one
/// lets go, so a holder that is disposed can never leave it stuck on.
class ScreenAwake {
  ScreenAwake._();

  static const MethodChannel _channel =
      MethodChannel('com.peerm.peerm_app/memory');

  static final Set<Object> _holders = {};
  static bool _on = false;

  @visibleForTesting
  static bool get isOn => _on;

  /// Adds or removes [holder]'s request.
  static void hold(Object holder, bool wanted) {
    final changed = wanted ? _holders.add(holder) : _holders.remove(holder);
    if (!changed) return;
    final on = _holders.isNotEmpty;
    if (on == _on) return;
    _on = on;
    _apply(on);
  }

  static void _apply(bool on) {
    try {
      if (Platform.isAndroid) {
        _channel.invokeMethod('setKeepScreenOn', {'on': on});
      } else if (Platform.isWindows) {
        _setExecutionState(
          on ? _esContinuous | _esDisplayRequired : _esContinuous,
        );
      }
    } catch (e) {
      debugPrint('[ScreenAwake] could not ${on ? 'hold' : 'release'} the screen: $e');
    }
  }

  static const int _esContinuous = 0x80000000;
  static const int _esDisplayRequired = 0x00000002;

  static final int Function(int) _setExecutionState = DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<Uint32 Function(Uint32), int Function(int)>(
    'SetThreadExecutionState',
  );
}
