@Tags(['render'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/lyrics_display.dart';
import 'package:peerm_app/services/lyrics_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/widgets/player/lyric_sync_sheet.dart';
import 'package:peerm_app/widgets/player/lyrics_view.dart';

/// Renders the lyrics card to PNGs in build/lyrics_renders so the look can be
/// checked without opening the app. Needs the Windows system fonts; skipped
/// elsewhere. Run with: flutter test --tags render test/lyrics_render_test.dart
class _ParkedPlayer extends AudioPlayer {
  _ParkedPlayer(this.at) : super(handleAudioSessionActivation: false);
  final Duration at;

  @override
  Duration get position => at;

  @override
  Duration? get duration => const Duration(minutes: 4);

  @override
  bool get playing => false;

  @override
  Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) => const Stream.empty();
}

Future<void> _loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

void main() {
  const fonts = r'C:\Windows\Fonts';
  final haveFonts = File('$fonts\\segoeui.ttf').existsSync();

  final song = Song(
    id: 'render_song',
    title: 'Render Song',
    fileName: 'render.m4a',
    size: 1,
    checksum: 'x',
    addedAt: DateTime(2026, 9, 29),
  );
  const lrc = '''
[00:10.00] Mother of this sacred dream that burns in us
[00:20.00] 夜に駆ける 君の手を引いて
[00:30.00] next
''';

  setUpAll(() async {
    if (!haveFonts) return;
    await _loadFont('Segoe UI', '$fonts\\segoeui.ttf');
    await _loadFont('Segoe UI', '$fonts\\segoeuib.ttf');
    await _loadFont('Segoe UI', '$fonts\\seguisb.ttf');
    await _loadFont('Yu Gothic', '$fonts\\YuGothM.ttc');
    // The icon font ships with the Flutter SDK running the test.
    final sdk = File(Platform.resolvedExecutable).parent.parent.parent.parent;
    final icons = File(
      '${sdk.path}\\artifacts\\material_fonts\\materialicons-regular.otf',
    );
    if (icons.existsSync()) await _loadFont('MaterialIcons', icons.path);
  });

  final out = Directory('build/lyrics_renders')..createSync(recursive: true);

  Future<void> render(
    WidgetTester tester,
    String name, {
    required List<Color> cover,
    required Color accent,
    required LyricsColorMode mode,
    required Duration at,
    double bottomInset = 0,
  }) async {
    LyricsService.setLyricsForTesting(song.id, lrc);
    LyricsDisplay.mode.value = mode;
    final key = GlobalKey();
    final player = PlayerService(LibraryService(), player: _ParkedPlayer(at));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'Segoe UI',
          fontFamilyFallback: const ['Yu Gothic'],
        ),
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: cover,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (bottomInset > 0)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          height: bottomInset - 12,
                          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          color: accent.withValues(alpha: 0.35),
                        ),
                      ),
                    LyricsView(
                      song: song,
                      player: player,
                      accent: accent,
                      size: 320,
                      bottomInset: bottomInset,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${out.path}/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
    LyricsDisplay.mode.value = LyricsColorMode.auto;
    LyricsService.clearMemoryCache();
  }

  const pale = [Color(0xFFC9D3D6), Color(0xFF8E9A9C), Color(0xFFD8DEDD)];
  const red = [Color(0xFF7A1010), Color(0xFF2A1414), Color(0xFF101010)];
  const greyTeal = Color(0xFF9BC4C4);
  const coral = Color(0xFFE8604C);
  const halfLine = Duration(seconds: 13, milliseconds: 500);

  testWidgets(
    'render the Lyrics Options dialog',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      LyricsService.setLyricsForTesting(song.id, lrc);
      final key = GlobalKey();
      final player = PlayerService(
        LibraryService(),
        player: _ParkedPlayer(Duration.zero),
      );
      final longTitle = Song(
        id: song.id,
        title:
            'going... - DENONBU, Aiobahn, Nagahara Tsugumi, and Mitsuki Seto (CV: Sister Claire)',
        fileName: song.fileName,
        size: 1,
        checksum: 'x',
        addedAt: song.addedAt,
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: Brightness.dark,
              fontFamily: 'Segoe UI',
              fontFamilyFallback: const ['Yu Gothic'],
            ),
            home: Builder(
              builder: (context) => Scaffold(
                backgroundColor: const Color(0xFF3A2A2E),
                body: Center(
                  child: TextButton(
                    onPressed: () => showLyricSyncSheet(
                      context,
                      song: longTitle,
                      player: player,
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${out.path}/lyrics_options.png',
        ).writeAsBytesSync(png!.buffer.asUint8List());
      });
      await tester.tap(find.byKey(const ValueKey('lyrics_options_close')));
      await tester.pumpAndSettle();
      LyricsService.clearMemoryCache();
    },
    skip: !haveFonts,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('render the lyrics card', (tester) async {
    await render(
      tester,
      'pale_black_text',
      cover: pale,
      accent: greyTeal,
      mode: LyricsColorMode.dark,
      at: halfLine,
    );
    await render(
      tester,
      'pale_black_text_visualizer',
      cover: pale,
      accent: greyTeal,
      mode: LyricsColorMode.dark,
      at: halfLine,
      bottomInset: 108,
    );
    await render(
      tester,
      'red_white_text',
      cover: red,
      accent: coral,
      mode: LyricsColorMode.light,
      at: halfLine,
    );
    await render(
      tester,
      'red_white_text_visualizer',
      cover: red,
      accent: coral,
      mode: LyricsColorMode.light,
      at: halfLine,
      bottomInset: 108,
    );
    await render(
      tester,
      'japanese_black_text',
      cover: pale,
      accent: coral,
      mode: LyricsColorMode.dark,
      at: const Duration(seconds: 21, milliseconds: 200),
    );
  }, skip: !haveFonts);
}
