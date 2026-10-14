// Renders the README screenshots offscreen with made-up songs and generated
// cover art, so no real library, album art or window is involved.
//
// Not part of the normal suite (it lives outside test/). Regenerate with:
//   flutter test tool/readme_shots/readme_shots_test.dart --update-goldens
// The PNGs land in .github/screenshots/, which the README shows.

// It is a widget test, just kept outside test/, so test-only hooks are fine here.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/main.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/player_theme.dart';
import 'package:peerm_app/services/video_service.dart';
import 'package:peerm_app/screens/home_shell.dart';
import 'package:peerm_app/widgets/player_bar.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _titles = [
  ('Paper Lanterns', 'Juniper Vale', 184),
  ('Northbound', 'The Quiet Hours', 92),
  ('Glasshouse Summer', 'Mara Lind', 71),
  ('Slow Tide', 'Harbor Lights', 58),
  ('Late Train Home', 'Orchard Street', 43),
  ('Honey & Static', 'Velvet Fern', 37),
  ('City of Small Hours', 'Kite Parade', 29),
  ('Wildflower Radio', 'Juniper Vale', 24),
  ('Undertow', 'Pale Coast', 18),
  ('Afterglow Drive', 'Neon Orchard', 12),
  ('Moss & Stone', 'Fieldnotes', 9),
  ('Weightless', 'Mara Lind', 7),
  ('Satellite Hearts', 'Kite Parade', 6),
  ('Blue Hour', 'Harbor Lights', 4),
];

// Sky, ground and accent colours for the cover styles below.
const _palettes = [
  [0xFFFFB86B, 0xFFE0457B, 0xFF3B1B5A],
  [0xFF7BDFF2, 0xFF3A7BD5, 0xFF0F2447],
  [0xFFF9E076, 0xFFEE7B4D, 0xFF5A1F3B],
  [0xFFB8F2C9, 0xFF2BA89A, 0xFF0C3B47],
  [0xFFE8B4FF, 0xFF7F5AF0, 0xFF1A1245],
  [0xFFFFD1DC, 0xFFFF6F91, 0xFF4A1942],
  [0xFFCDE7B0, 0xFF6BAA75, 0xFF173F35],
  [0xFFB2C7FF, 0xFF5C6BC0, 0xFF1B1F4D],
];

img.ColorRgb8 _rgb(int c) =>
    img.ColorRgb8((c >> 16) & 255, (c >> 8) & 255, c & 255);

img.ColorRgb8 _mix(int a, int b, double t) {
  final x = _rgb(a), y = _rgb(b);
  return img.ColorRgb8(
    (x.r + (y.r - x.r) * t).round(),
    (x.g + (y.g - x.g) * t).round(),
    (x.b + (y.b - x.b) * t).round(),
  );
}

/// A composed cover (sunset hills, rings, waves, blocks, night sky) in a
/// curated palette: reads as real album art without being anyone's.
String _cover(int seed) {
  final pal = _palettes[seed % _palettes.length];
  final style = (seed ~/ 2 + seed) % 5;
  const size = 360;
  final image = img.Image(width: size, height: size);
  final rnd = math.Random(seed * 53 + 11);

  // Vertical sky gradient for every style.
  for (var y = 0; y < size; y++) {
    final t = y / (size - 1);
    final c = _mix(pal[0], pal[1], math.pow(t, 1.15).toDouble());
    for (var x = 0; x < size; x++) {
      image.setPixel(x, y, c);
    }
  }

  switch (style) {
    case 0: // sunset hills
      img.fillCircle(image,
          x: size ~/ 2 + rnd.nextInt(60) - 30,
          y: (size * 0.52).round(),
          radius: 74,
          color: img.ColorRgba8(255, 244, 214, 235),
          antialias: true);
      for (var layer = 0; layer < 3; layer++) {
        final base = size * (0.62 + layer * 0.12);
        final c = _mix(pal[1], pal[2], 0.45 + layer * 0.25);
        final phase = rnd.nextDouble() * 6;
        for (var x = 0; x < size; x++) {
          final y = base + math.sin(x / 38 + phase) * (12 + layer * 4);
          img.drawLine(image,
              x1: x, y1: y.round(), x2: x, y2: size, color: c);
        }
      }
    case 1: // rings
      img.fill(image, color: _rgb(pal[2]));
      for (var i = 0; i < 7; i++) {
        final r = 160 - i * 22;
        img.drawCircle(image,
            x: size ~/ 2,
            y: size ~/ 2,
            radius: r,
            color: _mix(pal[0], pal[1], i / 6),
            antialias: true);
        img.drawCircle(image,
            x: size ~/ 2, y: size ~/ 2, radius: r - 1,
            color: _mix(pal[0], pal[1], i / 6), antialias: true);
        img.drawCircle(image,
            x: size ~/ 2, y: size ~/ 2, radius: r - 2,
            color: _mix(pal[0], pal[1], i / 6), antialias: true);
      }
      img.fillCircle(image,
          x: size ~/ 2, y: size ~/ 2, radius: 34, color: _rgb(pal[0]),
          antialias: true);
    case 2: // waves
      for (var band = 0; band < 6; band++) {
        final c = _mix(pal[0], pal[2], band / 5);
        final base = size * (0.18 + band * 0.14);
        final phase = band * 0.9 + rnd.nextDouble();
        for (var x = 0; x < size; x++) {
          final y = base + math.sin(x / 46 + phase) * 22;
          img.drawLine(image,
              x1: x, y1: y.round(), x2: x, y2: size, color: c);
        }
      }
    case 3: // blocks
      img.fill(image, color: _rgb(pal[2]));
      img.fillRect(image,
          x1: 0, y1: 0, x2: size ~/ 2, y2: size ~/ 2,
          color: _rgb(pal[0]));
      img.fillRect(image,
          x1: size ~/ 2, y1: size ~/ 2, x2: size, y2: size,
          color: _rgb(pal[1]));
      img.fillCircle(image,
          x: size ~/ 2, y: size ~/ 2, radius: 92,
          color: img.ColorRgba8(255, 255, 255, 235), antialias: true);
      img.fillCircle(image,
          x: size ~/ 2, y: size ~/ 2, radius: 54,
          color: _rgb(pal[2]), antialias: true);
    default: // night sky
      for (var y = 0; y < size; y++) {
        final c = _mix(pal[2], pal[1], math.pow(y / size, 2.2).toDouble());
        for (var x = 0; x < size; x++) {
          image.setPixel(x, y, c);
        }
      }
      for (var i = 0; i < 46; i++) {
        img.fillCircle(image,
            x: rnd.nextInt(size), y: rnd.nextInt((size * 0.7).round()),
            radius: 1 + rnd.nextInt(2),
            color: img.ColorRgba8(255, 255, 255, 120 + rnd.nextInt(130)),
            antialias: true);
      }
      img.fillCircle(image,
          x: 90 + rnd.nextInt(180), y: 90 + rnd.nextInt(60), radius: 38,
          color: _rgb(pal[0]), antialias: true);
      img.fillRect(image,
          x1: 0, y1: (size * 0.82).round(), x2: size, y2: size,
          color: _rgb(pal[2]));
  }

  // A touch of vignette so flat colour has some depth at big sizes.
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = (x - size / 2) / (size / 2);
      final dy = (y - size / 2) / (size / 2);
      final v = (dx * dx + dy * dy) * 0.18;
      final c = image.getPixel(x, y);
      image.setPixelRgb(
        x,
        y,
        (c.r * (1 - v)).round(),
        (c.g * (1 - v)).round(),
        (c.b * (1 - v)).round(),
      );
    }
  }
  return base64Encode(img.encodeJpg(image, quality: 90));
}

List<Song> _songs() => [
  for (var i = 0; i < _titles.length; i++)
    Song(
      id: 'demo_$i',
      title: '${_titles[i].$2} - ${_titles[i].$1}',
      // A video container, so the player offers its Video button.
      fileName: 'demo_$i.${i == 3 ? 'mp4' : 'mp3'}',
      size: _titles[i].$3 * 1024 * 1024 + i * 91234,
      checksum: 'demo_$i',
      artwork: _cover(i),
      addedAt: DateTime(2026, 9, 1).subtract(Duration(days: i)),
    ),
];

Future<void> _loadFonts() async {
  // flutter_tester runs from <sdk>/bin/cache/artifacts/engine/<platform>/.
  final exe = Platform.resolvedExecutable.replaceAll('\\', '/');
  final cache = exe.substring(0, exe.indexOf('/bin/cache/') + '/bin/cache'.length);
  final fonts = '$cache/artifacts/material_fonts';
  // The SDK ships Roboto-Regular.ttf and so on; match names ignoring case so
  // this also runs on case-sensitive file systems (Linux, macOS).
  String resolve(String path) {
    final file = File(path);
    if (file.existsSync()) return path;
    final name = path.split('/').last.toLowerCase();
    for (final entry in file.parent.listSync()) {
      if (entry.path.replaceAll('\\', '/').split('/').last.toLowerCase() == name) {
        return entry.path;
      }
    }
    return path;
  }

  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      final bytes = File(resolve(path)).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  final roboto = [
    for (final w in ['regular', 'medium', 'bold', 'light']) '$fonts/roboto-$w.ttf',
  ];
  // Windows builds render in Segoe UI; use it for the desktop shot when present.
  const winFonts = 'C:/Windows/Fonts';
  final segoe = [
    for (final f in ['segoeui.ttf', 'seguisb.ttf', 'segoeuib.ttf', 'segoeuil.ttf'])
      if (File('$winFonts/$f').existsSync()) '$winFonts/$f',
  ];
  await load('Roboto', roboto);
  await load('Segoe UI', segoe.isEmpty ? roboto : segoe);
  // flutter_test's default family, used when a style names no font.
  await load('FlutterTest', roboto);
  await load('MaterialIcons', ['$fonts/materialicons-regular.otf']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Song> songs;

  setUpAll(() async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => Directory.systemTemp.path);
    await _loadFonts();
    songs = _songs();
  });

  Future<Widget> buildApp({Song? playing}) async {
    SharedPreferences.setMockInitialValues({
      'peerm_favorite_song_ids': ['demo_0', 'demo_3', 'demo_6'],
    });
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService()..setSongsForTesting(songs);
    final history = HistoryService(prefs);
    final player = PlayerService(library, identity: identity, history: history);
    if (playing != null) {
      player.updateQueue(songs);
      player.currentSong = playing;
    }
    final controller = AppController(
      identity: identity,
      library: library,
      player: player,
      youtube: YoutubeService(),
      history: history,
    );
    return PearMusicApp(
      controller: controller,
      playerTheme: PlayerTheme(player),
      history: history,
      video: VideoService(player, library),
    );
  }

  Future<void> shoot(
    WidgetTester tester, {
    required String name,
    required Size size,
    required double dpr,
    Song? playing,
    TargetPlatform platform = TargetPlatform.android,
    bool expandPane = false,
    bool openPlayer = false,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    await tester.pumpWidget(await buildApp(playing: playing));
    // Let the covers decode (real image codecs need real async time).
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 400));
    }
    if (expandPane) {
      HomeShell.requestExpandedPane();
      // The expanded player builds a new, larger artwork: give its decode
      // real time too.
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    if (openPlayer) {
      await tester.tap(find.byType(PlayerBar));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
        await tester.pump(const Duration(milliseconds: 350));
      }
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../../../.github/screenshots/$name.png'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 12));
    debugDefaultTargetPlatformOverride = null;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  testWidgets('desktop library', (tester) async {
    await shoot(
      tester,
      name: 'desktop',
      size: const Size(1500, 900),
      dpr: 1.4,
      playing: songs[3],
      platform: TargetPlatform.windows,
      expandPane: true,
    );
  });

  testWidgets('phone library', (tester) async {
    await shoot(
      tester,
      name: 'phone',
      size: const Size(392, 820),
      dpr: 2,
      playing: songs[3],
    );
  });

  testWidgets('phone player', (tester) async {
    await shoot(
      tester,
      name: 'phone-player',
      size: const Size(392, 820),
      dpr: 2,
      playing: songs[3],
      openPlayer: true,
    );
  });
}
