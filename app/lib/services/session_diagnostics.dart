import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

final class _SystemPowerStatus extends Struct {
  @Uint8()
  external int acLineStatus;
  @Uint8()
  external int batteryFlag;
  @Uint8()
  external int batteryLifePercent;
  @Uint8()
  external int systemStatusFlag;
  @Uint32()
  external int batteryLifeTime;
  @Uint32()
  external int batteryFullLifeTime;
}

typedef _GetSystemPowerStatusNative = Int32 Function(Pointer<_SystemPowerStatus>);
typedef _GetSystemPowerStatusDart = int Function(Pointer<_SystemPowerStatus>);

class BatterySnapshot {
  final int? percent;
  final bool isCharging;
  final bool isAc;

  const BatterySnapshot({
    this.percent,
    this.isCharging = false,
    this.isAc = false,
  });
}

/// Tracks real-time session diagnostics including uptime, background vs
/// foreground duration, battery consumption delta, active audio playback time,
/// and peak memory usage. Resets when the application process terminates.
class SessionDiagnostics {
  static DateTime _sessionStartTime = DateTime.now();
  static Duration _foregroundAccumulated = Duration.zero;
  static Duration _backgroundAccumulated = Duration.zero;
  static DateTime _lastStateChange = DateTime.now();
  static AppLifecycleState _currentState = AppLifecycleState.resumed;

  static BatterySnapshot? _initialBattery;
  static BatterySnapshot? _latestBattery;
  static double _peakRssMb = 0.0;
  static Duration _playbackAccumulated = Duration.zero;
  static DateTime? _playbackStartTime;

  static const MethodChannel _androidBatteryChannel =
      MethodChannel('com.peerm.peerm_app/battery');
  static const MethodChannel _androidMemoryChannel =
      MethodChannel('com.peerm.peerm_app/memory');

  static bool _initialized = false;

  static void init({DateTime? startTime}) {
    if (_initialized) return;
    _initialized = true;
    _sessionStartTime = startTime ?? DateTime.now();
    _lastStateChange = _sessionStartTime;
    _currentState = AppLifecycleState.resumed;
    unawaited(updateBatterySnapshot());
  }

  @visibleForTesting
  static void resetForTesting({DateTime? startTime}) {
    _initialized = false;
    _sessionStartTime = startTime ?? DateTime.now();
    _foregroundAccumulated = Duration.zero;
    _backgroundAccumulated = Duration.zero;
    _lastStateChange = _sessionStartTime;
    _currentState = AppLifecycleState.resumed;
    _playbackAccumulated = Duration.zero;
    _playbackStartTime = null;
    _peakRssMb = 0.0;
    _initialBattery = null;
    _latestBattery = null;
  }

  static DateTime get sessionStartTime => _sessionStartTime;

  static void updatePlaybackState(bool isPlaying) {
    final now = DateTime.now();
    if (isPlaying) {
      _playbackStartTime ??= now;
    } else {
      if (_playbackStartTime != null) {
        _playbackAccumulated += now.difference(_playbackStartTime!);
        _playbackStartTime = null;
      }
    }
  }

  static Duration get totalPlaybackDuration {
    var dur = _playbackAccumulated;
    if (_playbackStartTime != null) {
      dur += DateTime.now().difference(_playbackStartTime!);
    }
    final uptime = sessionUptime;
    if (dur > uptime) {
      return uptime;
    }
    return dur;
  }

  static void onLifecycleChanged(AppLifecycleState state) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastStateChange);
    _lastStateChange = now;

    if (_currentState == AppLifecycleState.resumed) {
      _foregroundAccumulated += elapsed;
    } else {
      _backgroundAccumulated += elapsed;
    }
    _currentState = state;
    unawaited(updateBatterySnapshot());
  }

  static Duration get foregroundDuration {
    var dur = _foregroundAccumulated;
    if (_currentState == AppLifecycleState.resumed) {
      dur += DateTime.now().difference(_lastStateChange);
    }
    return dur;
  }

  static Duration get backgroundDuration {
    var dur = _backgroundAccumulated;
    if (_currentState != AppLifecycleState.resumed) {
      dur += DateTime.now().difference(_lastStateChange);
    }
    return dur;
  }

  static Duration get sessionUptime => foregroundDuration + backgroundDuration;

  static void recordRss(double currentRssMb) {
    if (currentRssMb > _peakRssMb) {
      _peakRssMb = currentRssMb;
    }
  }

  static double get peakRssMb => _peakRssMb;

  static Future<double?> getNativePssMb() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final res = await _androidMemoryChannel.invokeMapMethod<String, dynamic>('getPssMemoryInfo');
      if (res != null && res['pssMb'] is num) {
        return (res['pssMb'] as num).toDouble();
      }
    } catch (_) {}
    return null;
  }

  static Future<BatterySnapshot?> updateBatterySnapshot() async {
    final snapshot = await _readBattery();
    if (snapshot != null) {
      _initialBattery ??= snapshot;
      _latestBattery = snapshot;
    }
    return snapshot;
  }

  static BatterySnapshot? get initialBattery => _initialBattery;
  static BatterySnapshot? get latestBattery => _latestBattery;

  static Future<BatterySnapshot?> _readBattery() async {
    if (kIsWeb) return null;

    if (Platform.isAndroid) {
      try {
        final res = await _androidBatteryChannel.invokeMapMethod<String, dynamic>('getBatteryInfo');
        if (res != null) {
          final pct = res['percent'] as int?;
          final isCharging = res['isCharging'] as bool? ?? false;
          final isAc = res['isAc'] as bool? ?? false;
          if (pct != null && pct >= 0) {
            return BatterySnapshot(
              percent: pct,
              isCharging: isCharging,
              isAc: isAc,
            );
          }
        }
      } catch (_) {}
      return null;
    }

    if (Platform.isWindows) {
      try {
        final k32 = DynamicLibrary.open('kernel32.dll');
        final getStatus = k32.lookupFunction<_GetSystemPowerStatusNative, _GetSystemPowerStatusDart>('GetSystemPowerStatus');
        final ptr = calloc<_SystemPowerStatus>();
        try {
          final res = getStatus(ptr);
          if (res != 0) {
            final ac = ptr.ref.acLineStatus;
            final flag = ptr.ref.batteryFlag;
            final pct = ptr.ref.batteryLifePercent;
            final isAc = ac == 1;
            final isCharging = (flag & 8) != 0 || (isAc && pct == 100);
            return BatterySnapshot(
              percent: pct <= 100 ? pct : null,
              isCharging: isCharging,
              isAc: isAc,
            );
          }
        } finally {
          calloc.free(ptr);
        }
      } catch (_) {}
    }

    return null;
  }

  static String formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h}h ${m}m';
    }
    if (m > 0) {
      return '${m}m ${s}s';
    }
    return '${s}s';
  }

  static String getBatterySummary() {
    final cur = _latestBattery;
    final init = _initialBattery;
    if (cur == null || cur.percent == null) {
      return 'N/A';
    }

    if (cur.isCharging) {
      final delta = init?.percent != null ? cur.percent! - init!.percent! : 0;
      final deltaStr = delta > 0 ? ' (+$delta%)' : '';
      return '${cur.percent}% (Charging$deltaStr)';
    }

    if (init != null && init.percent != null) {
      final delta = init.percent! - cur.percent!;
      final uptimeHours = sessionUptime.inSeconds / 3600.0;
      if (delta > 0 && uptimeHours >= 0.05) {
        final rate = (delta / uptimeHours).toStringAsFixed(1);
        return '-$delta% (${init.percent}% -> ${cur.percent}%, ~$rate%/h)';
      } else if (delta > 0) {
        return '-$delta% (${init.percent}% -> ${cur.percent}%)';
      } else if (delta == 0) {
        return '0% (${cur.percent}%)';
      } else {
        return '+${-delta}% (${cur.percent}%)';
      }
    }

    return '${cur.percent}%';
  }
}
