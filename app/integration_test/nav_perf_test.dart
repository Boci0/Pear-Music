import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/main.dart' as app;
import 'package:provider/provider.dart';
import 'package:peerm_app/screens/home_shell.dart';

/// Frame-time profile of the real app on this machine: idle, switching every
/// tab, and scrolling the library. Run in profile mode (debug numbers mean
/// nothing):
///
///   flutter test integration_test/nav_perf_test.dart -d windows --profile
///
/// Prints build and raster times per phase and how many frames missed the
/// 60 Hz budget. Plays no audio.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String>[];
  void say(String line) {
    report.add(line);
    // ignore: avoid_print
    print(line);
    binding.reportData = {'perf': List<String>.of(report)};
  }

  String stats(String name, List<FrameTiming> t, Duration wall) {
    if (t.isEmpty) return 'PERF $name: no frames in ${wall.inSeconds}s (the app was idle)';
    double ms(Duration d) => d.inMicroseconds / 1000;
    double pct(List<double> v, double p) {
      final s = [...v]..sort();
      return s[((s.length - 1) * p).round()];
    }

    final build = t.map((f) => ms(f.buildDuration)).toList();
    final raster = t.map((f) => ms(f.rasterDuration)).toList();
    final total = t.map((f) => ms(f.totalSpan)).toList();
    final over16 = total.where((v) => v > 16.7).length;
    final over33 = total.where((v) => v > 33.4).length;
    double avg(List<double> v) => v.reduce((a, b) => a + b) / v.length;
    return 'PERF $name: ${t.length} frames in ${wall.inMilliseconds}ms '
        '(${(t.length / (wall.inMilliseconds / 1000)).toStringAsFixed(0)} fps) | '
        'build avg ${avg(build).toStringAsFixed(1)} p90 ${pct(build, .9).toStringAsFixed(1)} max ${build.reduce((a, b) => a > b ? a : b).toStringAsFixed(1)} ms | '
        'raster avg ${avg(raster).toStringAsFixed(1)} p90 ${pct(raster, .9).toStringAsFixed(1)} max ${raster.reduce((a, b) => a > b ? a : b).toStringAsFixed(1)} ms | '
        'total >16.7ms: $over16 (${(over16 * 100 / t.length).toStringAsFixed(0)}%), >33ms: $over33';
  }

  testWidgets('frame times: idle, tab switching, library scroll', (tester) async {
    app.main();
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(HomeShell).evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(HomeShell), findsOneWidget);

    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    say('PERF window: ${size.width.toInt()} x ${size.height.toInt()} dp, dpr ${tester.view.devicePixelRatio}');

    final timings = <FrameTiming>[];
    void collect(List<FrameTiming> t) => timings.addAll(t);
    WidgetsBinding.instance.addTimingsCallback(collect);

    Future<void> phase(String name, Future<void> Function() body) async {
      timings.clear();
      final sw = Stopwatch()..start();
      await body();
      // Timings arrive in batches; give the last one a moment.
      await tester.pump(const Duration(milliseconds: 600));
      sw.stop();
      say(stats(name, List.of(timings), sw.elapsed));
    }

    await phase('idle (8s)', () async {
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    });

    const labels = ['Playlists', 'Explore', 'History', 'Settings', 'Library'];
    await phase('tab switching (3 rounds)', () async {
      for (var round = 0; round < 3; round++) {
        for (final label in labels) {
          final f = find.text(label);
          if (f.evaluate().isEmpty) continue;
          await tester.tap(f.last);
          for (var i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
        }
      }
    });

    final scrollables = find.byType(Scrollable);
    if (scrollables.evaluate().isNotEmpty) {
      await phase('library scroll (down, up)', () async {
        for (var round = 0; round < 3; round++) {
          await tester.fling(scrollables.first, const Offset(0, -600), 1500);
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          await tester.fling(scrollables.first, const Offset(0, 600), 1500);
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
        }
      });
    }
    // Playback, silently: volume 0 for the whole phase, then put it back. The
    // visualizer and the Now Playing pane animate while a song plays, and that
    // is what the idle and navigation phases above leave out.
    final controller = Provider.of<AppController>(
      tester.element(find.byType(HomeShell)),
      listen: false,
    );
    final player = controller.player;
    final originalVolume = player.volume;
    addTearDown(() async {
      await player.setVolume(originalVolume);
      await player.pause();
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    if (controller.songs.isEmpty) {
      say('PERF playback: skipped, the library has no songs');
    } else {
      await player.setVolume(0);
      say('PERF clock: playback phase starts at ${DateTime.now().toIso8601String()}');
      await controller.playSong(controller.songs.first);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await phase('playing, muted (12s)', () async {
        for (var i = 0; i < 120; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      });
      await phase('tab switching while playing', () async {
        for (var round = 0; round < 3; round++) {
          for (final label in labels) {
            final f = find.text(label);
            if (f.evaluate().isEmpty) continue;
            await tester.tap(f.last);
            for (var i = 0; i < 12; i++) {
              await tester.pump(const Duration(milliseconds: 50));
            }
          }
        }
      });
      await player.pause();
      say('PERF clock: playback phase ends at ${DateTime.now().toIso8601String()}');
    }
    await player.setVolume(originalVolume);
    WidgetsBinding.instance.removeTimingsCallback(collect);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
