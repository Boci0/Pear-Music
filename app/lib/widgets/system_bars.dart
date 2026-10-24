import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A phone held sideways hides the status and navigation bars: the short
/// screen needs every row (a swipe from the edge still shows them). The shell
/// reports the orientation; fullscreen video sets its own mode and hands back
/// through [restore].
class SystemBars {
  static bool _sideways = false;

  static bool get _phone =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static void setSideways(bool sideways) {
    if (sideways == _sideways) return;
    _sideways = sideways;
    restore();
  }

  static void restore() {
    if (!_phone) return;
    SystemChrome.setEnabledSystemUIMode(
      _sideways ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }
}
