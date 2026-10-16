import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'window_focus.dart';

/// Parks rendering while the Windows window is minimized or entirely covered
/// by other windows.
///
/// A covered window still gets frames from the engine, and with the default
/// renderer that piles up native memory (about 30 MB a second with a playing
/// player, until a garbage collection frees it). Nothing is on screen to
/// animate, so while covered the app reports itself `hidden`, which stops the
/// framework scheduling frames and parks the visualizer, glows and lyrics
/// through the same path a minimized window already takes. Audio is not
/// touched. Any pointer or key event proves the window is in use and lifts
/// the hold at once, so a wrong guess can never leave the window frozen.
class WindowOcclusion with WidgetsBindingObserver {
  WindowOcclusion._(this._sample, this._interval);

  /// True while the window is covered or minimized (and frames are parked).
  static final ValueNotifier<bool> covered = ValueNotifier<bool>(false);

  static WindowOcclusion? _instance;

  /// Starts watching the real window. Windows only; a no-op elsewhere and
  /// when already started.
  static void start() {
    if (_instance != null || kIsWeb || !Platform.isWindows) return;
    _instance = WindowOcclusion._(
      _WindowsSampler().isCovered,
      const Duration(seconds: 1),
    )._begin();
  }

  /// A watcher driven by [sample], for tests.
  @visibleForTesting
  static WindowOcclusion startForTest(
    bool Function() sample, {
    Duration interval = const Duration(seconds: 1),
  }) {
    _instance?.dispose();
    return _instance = WindowOcclusion._(sample, interval)._begin();
  }

  final bool Function() _sample;
  final Duration _interval;
  Timer? _timer;
  int _coveredSamples = 0;
  bool _applying = false;

  /// Samples in a row that must say covered before the hold starts, so a
  /// window dragged across the screen for a moment is not parked.
  static const int _samplesToCover = 2;

  WindowOcclusion _begin() {
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
    _timer = Timer.periodic(_interval, (_) => _poll());
    return this;
  }

  @visibleForTesting
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    if (covered.value) _set(false);
    if (identical(_instance, this)) _instance = null;
  }

  void _poll() {
    final isCovered = _sample();
    if (!isCovered) {
      _coveredSamples = 0;
      _set(false);
      return;
    }
    if (++_coveredSamples >= _samplesToCover) _set(true);
  }

  void _onPointer(PointerEvent event) => _inUse();

  bool _onKey(KeyEvent event) {
    _inUse();
    return false;
  }

  void _inUse() {
    // Restart the count so the next poll cannot re-cover on stale samples.
    _coveredSamples = 0;
    if (covered.value) _set(false);
  }

  void _set(bool value) {
    if (covered.value == value) return;
    covered.value = value;
    _report(
      value
          ? AppLifecycleState.hidden
          : (WindowFocus.focused.value
                ? AppLifecycleState.resumed
                : AppLifecycleState.inactive),
    );
  }

  void _report(AppLifecycleState state) {
    _applying = true;
    try {
      WidgetsBinding.instance.handleAppLifecycleStateChanged(state);
    } finally {
      _applying = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The embedder reports focus changes too; while covered, put the hold
    // back so one of those cannot switch frames on again.
    if (_applying || !covered.value || state == AppLifecycleState.hidden) {
      return;
    }
    scheduleMicrotask(() {
      if (covered.value) _report(AppLifecycleState.hidden);
    });
  }
}

/// Finds this process's window and asks whether any part of it is on top.
///
/// Covered means: minimized, or none of a grid of points inside it belongs to
/// the window itself. A window that is partly visible, or partly off screen,
/// is never covered.
class _WindowsSampler {
  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final int Function(int, int, Pointer<Utf16>, int) _findWindowEx =
      _user32.lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, IntPtr),
        int Function(int, int, Pointer<Utf16>, int)
      >('FindWindowExW');
  static final int Function(int, Pointer<Uint32>) _threadProcess = _user32
      .lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetWindowThreadProcessId');
  static final int Function() _currentProcess = _kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
  static final int Function(int) _isIconic = _user32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');
  static final int Function(int) _isWindow = _user32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');
  static final int Function(int, Pointer<Int32>) _windowRect = _user32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Int32>),
        int Function(int, Pointer<Int32>)
      >('GetWindowRect');
  // POINT is two 32-bit ints, passed in one 64-bit register on x64.
  static final int Function(int) _windowFromPoint = _user32
      .lookupFunction<IntPtr Function(Int64), int Function(int)>(
        'WindowFromPoint',
      );
  static final int Function(int, int) _ancestor = _user32
      .lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>(
        'GetAncestor',
      );
  static final int Function(int) _metric = _user32
      .lookupFunction<Int32 Function(Int32), int Function(int)>(
        'GetSystemMetrics',
      );

  static const _gaRoot = 2;

  int _hwnd = 0;

  int _findOwnWindow() {
    if (_hwnd != 0 && _isWindow(_hwnd) != 0) return _hwnd;
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final pid = calloc<Uint32>();
    try {
      var prev = 0;
      final mine = _currentProcess();
      for (var i = 0; i < 16; i++) {
        final h = _findWindowEx(0, prev, cls, 0);
        if (h == 0) break;
        _threadProcess(h, pid);
        if (pid.value == mine) return _hwnd = h;
        prev = h;
      }
    } finally {
      calloc.free(cls);
      calloc.free(pid);
    }
    return _hwnd = 0;
  }

  bool isCovered() {
    try {
      final hwnd = _findOwnWindow();
      if (hwnd == 0) return false;
      if (_isIconic(hwnd) != 0) return true;
      final rect = calloc<Int32>(4);
      try {
        if (_windowRect(hwnd, rect) == 0) return false;
        final left = rect[0], top = rect[1];
        final width = rect[2] - left, height = rect[3] - top;
        if (width < 40 || height < 40) return false;
        final vx = _metric(76), vy = _metric(77);
        final vw = _metric(78), vh = _metric(79);
        var sampled = 0;
        for (final fy in const [0.15, 0.5, 0.85]) {
          for (final fx in const [0.12, 0.37, 0.63, 0.88]) {
            final x = (left + width * fx).round();
            final y = (top + height * fy).round();
            // Off screen is not "covered by a window": skip it.
            if (x < vx || y < vy || x >= vx + vw || y >= vy + vh) continue;
            sampled++;
            final at = _windowFromPoint((y << 32) | (x & 0xFFFFFFFF));
            if (at != 0 && _ancestor(at, _gaRoot) == hwnd) return false;
          }
        }
        return sampled > 0;
      } finally {
        calloc.free(rect);
      }
    } catch (_) {
      return false;
    }
  }
}
