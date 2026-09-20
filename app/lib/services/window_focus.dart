import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Tracks whether the app's top-level window currently has OS input focus.
///
/// Flutter's app lifecycle on Windows only reports minimize/restore, so a
/// visible-but-unfocused window keeps rendering animations indefinitely. The
/// native runner pushes WM_ACTIVATE transitions over this channel so widgets
/// like the artwork visualizer and the glow pulse can pause when the app is
/// open on screen but not being used.
///
/// On platforms without the channel (mobile, web) [focused] stays true and the
/// regular platform lifecycle drives backgrounding instead.
class WindowFocus {
  WindowFocus._();

  /// True while the window has input focus. Tests and non-Windows platforms
  /// always see true.
  static final ValueNotifier<bool> focused = ValueNotifier<bool>(true);

  static const MethodChannel _channel = MethodChannel('peerm/window_focus');

  static bool _initialized = false;

  /// Wires the native focus channel. Safe to call more than once.
  static void init() {
    if (_initialized) return;
    if (kIsWeb || !Platform.isWindows) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onActivate') {
        final args = call.arguments;
        focused.value = args is bool ? args : true;
      }
      return null;
    });
  }
}
