// Renders the README screenshots offscreen with made-up songs and generated
// cover art, so no real library, album art or window is involved.
//
// Not part of the normal suite (it lives outside test/). Regenerate with:
//   flutter test tool/readme_shots/readme_shots_test.dart --update-goldens
// The PNGs land in .github/screenshots/, which the README shows.

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

const _palettes = [
  [0xFFB8D943, 0xFF2E6B3A],
  [0xFF5B8DEF, 0xFF1B2A6B],
  [0xFFF2A65A, 0xFF8C2F39],
  [0xFF47C1BF, 0xFF1D4E5F],
  [0xFFE86F9C, 0xFF4B1D6B],
  [0xFFF4D35E, 0xFFEE964B],
  [0xFF9B8CFF, 0xFF2B2356],
];

/// A soft two-colour gradient with a few circles: reads as cover art at
/// thumbnail size without being anyone's real artwork.
String _cover(int seed) {
  final pal = _palettes[seed % _palettes.length];
  final a = img.ColorRgb8((pal[0] >> 16) & 255, (pal[0] >> 8) & 255, pal[0] & 255);
  final b = img.ColorRgb8((pal[1] >> 16) & 255, (pal[1] >> 8) & 255, pal[1] & 255);
  const size = 320;
  final image = img.Image(width: size, height: size);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final t = ((x + y) / (2 * size)).clamp(0.0, 1.0);
      image.setPixelRgb(
        x,
        y,
        (a.r * (1 - t) + b.r * t).round(),
        (a.g * (1 - t) + b.g * t).round(),
        (a.b * (1 - t) + b.b * t).round(),
      );
    }
  }
  final rnd = math.Random(seed * 31 + 7);
  for (var i = 0; i < 3; i++) {
    img.fillCircle(
      image,
      x: rnd.nextInt(size),
      y: rnd.nextInt(size),
      radius: 40 + rnd.nextInt(90),
      color: img.ColorRgba8(255, 255, 255, 28 + rnd.nextInt(40)),
      antialias: true,
    );
  }
  return base64Encode(img.encodeJpg(image, quality: 88));
}

List<Song> _songs() => [
  for (var i = 0; i < _titles.length; i++)
    Song(
      id: 'demo_$i',
      title: '${_titles[i].$2} - ${_titles[i].$1}',
      fileName: 'demo_$i.mp3',
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
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      final bytes = File(path).readAsBytesSync();
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
    );
  }

  Future<void> shoot(
    WidgetTester tester, {
    required String name,
    required Size size,
    required double dpr,
    Song? playing,
    TargetPlatform platform = TargetPlatform.android,
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
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../../../.github/screenshots/$name.png'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    debugDefaultTargetPlatformOverride = null;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  testWidgets('desktop library', (tester) async {
    await shoot(
      tester,
      name: 'desktop',
      size: const Size(1440, 880),
      dpr: 1,
      playing: songs[3],
      platform: TargetPlatform.windows,
    );
  });

  testWidgets('phone library', (tester) async {
    await shoot(tester, name: 'phone', size: const Size(392, 820), dpr: 2);
  });
}
