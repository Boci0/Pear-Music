import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/session_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SessionDiagnostics tracks formatDuration accurately', () {
    expect(SessionDiagnostics.formatDuration(const Duration(seconds: 45)), '45s');
    expect(SessionDiagnostics.formatDuration(const Duration(minutes: 5, seconds: 12)), '5m 12s');
    expect(SessionDiagnostics.formatDuration(const Duration(hours: 2, minutes: 15, seconds: 30)), '2h 15m');
  });

  test('SessionDiagnostics tracks playback state and duration', () async {
    SessionDiagnostics.resetForTesting();
    SessionDiagnostics.init();
    SessionDiagnostics.updatePlaybackState(true);
    await Future.delayed(const Duration(milliseconds: 50));
    SessionDiagnostics.updatePlaybackState(false);
    expect(SessionDiagnostics.totalPlaybackDuration.inMilliseconds, greaterThanOrEqualTo(40));
  });

  test('SessionDiagnostics lifecycle changes accumulate duration', () async {
    SessionDiagnostics.init();
    final initialFg = SessionDiagnostics.foregroundDuration;
    SessionDiagnostics.onLifecycleChanged(AppLifecycleState.paused);
    await Future.delayed(const Duration(milliseconds: 50));
    SessionDiagnostics.onLifecycleChanged(AppLifecycleState.resumed);
    expect(SessionDiagnostics.backgroundDuration.inMilliseconds, greaterThanOrEqualTo(40));
    expect(SessionDiagnostics.foregroundDuration, greaterThanOrEqualTo(initialFg));
  });

  test('SessionDiagnostics peak RSS tracks maxima', () {
    SessionDiagnostics.recordRss(50.0);
    SessionDiagnostics.recordRss(120.5);
    SessionDiagnostics.recordRss(80.0);
    expect(SessionDiagnostics.peakRssMb, 120.5);
  });

  test('SessionDiagnostics sessionUptime equals foreground + background and clamps playback', () async {
    SessionDiagnostics.resetForTesting();
    SessionDiagnostics.init();
    final initialUptime = SessionDiagnostics.sessionUptime;
    final initialComponents = SessionDiagnostics.foregroundDuration + SessionDiagnostics.backgroundDuration;
    expect((initialUptime - initialComponents).inMilliseconds.abs(), lessThanOrEqualTo(1));

    SessionDiagnostics.updatePlaybackState(true);
    await Future.delayed(const Duration(milliseconds: 60));
    SessionDiagnostics.onLifecycleChanged(AppLifecycleState.paused);
    await Future.delayed(const Duration(milliseconds: 60));
    SessionDiagnostics.onLifecycleChanged(AppLifecycleState.resumed);

    final fg = SessionDiagnostics.foregroundDuration;
    final bg = SessionDiagnostics.backgroundDuration;
    final uptime = SessionDiagnostics.sessionUptime;
    final playback = SessionDiagnostics.totalPlaybackDuration;

    expect(uptime.inMilliseconds, greaterThanOrEqualTo(fg.inMilliseconds + bg.inMilliseconds - 1));
    expect(playback.inMilliseconds, lessThanOrEqualTo(uptime.inMilliseconds));
  });
}
