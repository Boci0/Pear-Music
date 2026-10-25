// Design gallery: every visible part of the app on a few sheets, drawn by the
// app's own widgets so it renders exactly like the app.
//
// Run:   flutter run -d windows -t lib/dev/gallery_main.dart
// Build: flutter build windows --release --no-pub -t lib/dev/gallery_main.dart
// Args:  --sheet=parts|rows|panes|phone|desktop|players|screens
//        --tab=N (HomeShell tab to show)
//        --song=<part of a title> (the song shown as playing)
//        --index=<path> (use this index.json, e.g. a made-up demo library,
//          instead of a copy of the app's own)
//        --bare=home|player|phone-home|phone-player (no sheet: that screen alone, filling the window,
//          for README screenshots)
//
// It reads a copy of the library index (real titles and covers) from a temp
// folder and uses in-memory settings, so it never writes the app's own data.
// Nothing plays: the "playing" song is set directly on the player.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../screens/home_shell.dart';
import '../widgets/player/stream_quality_info_dialog.dart';
import '../widgets/player/playback_speed_dialog.dart';
import '../widgets/player/lyric_sync_sheet.dart';
import '../widgets/player/sleep_timer_dialog.dart';
import '../screens/history_screen.dart';
import '../screens/playlists_screen.dart';
import '../screens/player_screen.dart';
import '../screens/settings_screen.dart';
import '../services/artwork_palette.dart';
import '../services/history_service.dart';
import '../services/identity_service.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/player_theme.dart';
import '../services/youtube_search_service.dart';
import '../services/youtube_service.dart';
import '../theme/glass.dart';
import '../widgets/now_playing_panel.dart';
import '../widgets/pear_backdrop.dart';
import '../widgets/pear_status_bar.dart';
import '../widgets/player/player_artwork.dart';
import '../widgets/player/player_controls.dart';
import '../widgets/player_bar.dart';
import '../widgets/song_tile.dart';
import '../widgets/youtube_song_tile.dart';

const _sheets = [
  'parts',
  'rows',
  'panes',
  'phone',
  'desktop',
  'players',
  'screens',
  'sideways',
];

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  String arg(String name, String fallback) => args
      .firstWhere((a) => a.startsWith('--$name='), orElse: () => '=$fallback')
      .split('=')
      .last;

  // In-memory settings: the gallery must never touch the app's own prefs.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final tmp = await Directory.systemTemp.createTemp('pear_gallery');
  final appData = Platform.environment['APPDATA'];
  final indexArg = arg('index', '');
  if (appData != null) {
    final index = indexArg.isNotEmpty
        ? File(indexArg)
        : File(p.join(appData, 'com.peerm', 'peerm_app', 'index.json'));
    if (await index.exists()) {
      await index.copy(p.join(tmp.path, 'index.json'));
      // The library drops songs whose audio file is missing, so give each one
      // a 1-byte stand-in in the temp folder (nothing here ever plays).
      final dir = Directory(p.join(tmp.path, 'library'))..createSync();
      final entries = jsonDecode(await index.readAsString()) as List;
      for (final e in entries.whereType<Map<String, dynamic>>()) {
        final name = e['fileName'];
        if (name is String) File(p.join(dir.path, name)).writeAsBytesSync([0]);
      }
    }
  }
  // ignore: invalid_use_of_visible_for_testing_member
  final library = LibraryService()..debugBaseDirectory = tmp;
  await library.init();
  final identity = IdentityService(prefs);
  final history = HistoryService(prefs);
  final player = PlayerService(library, identity: identity, history: history);
  final controller = AppController(
    identity: identity,
    library: library,
    player: player,
    youtube: YoutubeService(),
    history: history,
  );

  final songs = library.songs;
  if (songs.isNotEmpty) {
    final pick = arg('song', 'Arsonist').toLowerCase();
    final current = songs.firstWhere(
      (s) => s.title.toLowerCase().contains(pick),
      orElse: () => songs.first,
    );
    player.updateQueue(songs, sourceId: 'gallery', sourceTitle: 'Library');
    player.currentSong = current;
    for (final s in songs) {
      ArtworkPalette.bytes(s);
    }
    await ArtworkPalette.dominant(current);
  }
  // Phone frames should lay out the player as a phone does, not as a narrow
  // Windows window.
  PlayerScreen.debugPhoneLayout = true;
  final theme = PlayerTheme(player);
  final tab = int.tryParse(arg('tab', ''));
  if (tab != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      HomeShell.requestTab(tab);
    });
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        ChangeNotifierProvider<IdentityService>.value(value: identity),
        ChangeNotifierProvider<LibraryService>.value(value: library),
        ChangeNotifierProvider<PlayerService>.value(value: player),
        ChangeNotifierProvider<HistoryService>.value(value: history),
        ChangeNotifierProvider<PlayerTheme>.value(value: theme),
      ],
      child: _GalleryApp(
        initialSheet: arg('sheet', 'parts'),
        open: arg('open', ''),
        bare: arg('bare', ''),
      ),
    ),
  );
}

class _GalleryApp extends StatefulWidget {
  const _GalleryApp({
    required this.initialSheet,
    this.open = '',
    this.bare = '',
  });
  final String initialSheet;

  /// Show one screen alone instead of a sheet (see the header).
  final String bare;

  /// A dialog to open once the window is up: sleep, speed or info.
  final String open;

  @override
  State<_GalleryApp> createState() => _GalleryAppState();
}

class _GalleryAppState extends State<_GalleryApp> {
  late String _sheet = _sheets.contains(widget.initialSheet)
      ? widget.initialSheet
      : 'parts';
  final _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    if (widget.open.isNotEmpty) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        final ctx = _navKey.currentContext;
        if (ctx != null && ctx.mounted) _openDialog(ctx, widget.open);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pear Gallery',
      navigatorKey: _navKey,
      theme: context.watch<PlayerTheme>().theme,
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [const PearBackdrop(), child ?? const SizedBox()],
      ),
      home: widget.bare.isNotEmpty
          ? _bareScreen(widget.bare)
          : Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TopBar(sheet: _sheet, onSheet: (s) => setState(() => _sheet = s)),
            Expanded(child: _sheetBody(_sheet)),
          ],
        ),
      ),
    );
  }

  /// One screen alone. 'phone-home' and 'phone-player' draw a 390 x 844 phone
  /// scaled to fill the window, like a sheet frame but sharp.
  Widget _bareScreen(String name) => switch (name) {
    'phone-home' => _phoneFill(const HomeShell()),
    'phone-player' => _phoneFill(const PlayerScreen()),
    'player' => const _FrameNavigator(PlayerScreen()),
    _ => const HomeShell(),
  };

  Widget _phoneFill(Widget child) {
    const size = Size(390, 844);
    return Builder(
      builder: (context) => FittedBox(
        child: SizedBox.fromSize(
          size: size,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: size,
              padding: EdgeInsets.zero,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [const PearBackdrop(), _FrameNavigator(child)],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sheetBody(String sheet) => switch (sheet) {
    'rows' => const _RowsSheet(),
    'panes' => const _PanesSheet(),
    'phone' => const _PhoneSheet(),
    'desktop' => const _DesktopSheet(),
    'players' => const _PlayersSheet(),
    'screens' => const _ScreensSheet(),
    'sideways' => const _SidewaysSheet(),
    _ => const _PartsSheet(),
  };
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.sheet, required this.onSheet});
  final String sheet;
  final ValueChanged<String> onSheet;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          for (final s in _sheets)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(s),
                selected: s == sheet,
                onSelected: (_) => onSheet(s),
              ),
            ),
        ],
      ),
    );
  }
}

/// One labelled specimen on a sheet.
class _Spec extends StatelessWidget {
  const _Spec(this.label, this.child, {this.width, this.height});
  final String label;
  final Widget child;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.white54),
        ),
        const SizedBox(height: 4),
        SizedBox(width: width, height: height, child: child),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              letterSpacing: 1.2,
              color: Colors.white70,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 22, runSpacing: 16, children: children),
        ],
      ),
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet(this.sections);
  final List<Widget> sections;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: sections,
    ),
  );
}

Song? _current(BuildContext context) =>
    context.watch<PlayerService>().currentSong;

List<Song> _songs(BuildContext context) =>
    context.watch<LibraryService>().songs;

class _PartsSheet extends StatelessWidget {
  const _PartsSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final player = context.watch<PlayerService>();
    final controller = context.read<AppController>();
    final song = _current(context);
    final accent = song == null
        ? scheme.primary
        : ArtworkPalette.dominantSync(song);
    Widget swatch(String name, Color c) => _Spec(
      name,
      DecoratedBox(
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24),
        ),
      ),
      width: 96,
      height: 56,
    );
    Widget type(String name, TextStyle? s) =>
        _Spec(name, Text('Arsonist · Local Library', style: s), width: 300);
    return _Sheet([
      _Section('Colour', [
        swatch('song accent', accent),
        swatch('primary', scheme.primary),
        swatch('surface', scheme.surface),
        swatch('surface high', scheme.surfaceContainerHighest),
        swatch('card fill opaque', PlayerTheme.cardFillOpaque(scheme)),
        swatch('on surface', scheme.onSurface),
      ]),
      _Section('Type', [
        type('headlineSmall', theme.textTheme.headlineSmall),
        type('titleLarge', theme.textTheme.titleLarge),
        type('titleMedium', theme.textTheme.titleMedium),
        type('titleSmall', theme.textTheme.titleSmall),
        type('bodyMedium', theme.textTheme.bodyMedium),
        type('bodySmall', theme.textTheme.bodySmall),
        type('labelSmall', theme.textTheme.labelSmall),
      ]),
      if (song != null)
        _Section('Player parts', [
          _Spec(
            'cover (300)',
            PlayerArtworkHero(
              song: song,
              size: 300,
              artwork: ArtworkPalette.cachedBytes(song),
              accent: accent,
              videoEnabled: true,
            ),
            width: 340,
          ),
          _Spec(
            'song info / compact',
            Column(
              children: [
                PlayerSongInfo(song: song),
                const SizedBox(height: 16),
                PlayerSongInfo(song: song, compact: true),
              ],
            ),
            width: 420,
          ),
          _Spec(
            'transport',
            PlayerTransport(
              player: player,
              controller: controller,
              accent: accent,
            ),
            width: 420,
          ),
          _Spec(
            'seek bar',
            PlayerSeekBar(
              player: player,
              duration: const Duration(minutes: 4),
              accent: accent,
            ),
            width: 420,
          ),
          _Spec('volume', PlayerVolumeRow(accent: accent), width: 420),
        ]),
      _Section('Chrome', [
        _Spec('status bar', const PearStatusBar(), width: 900),
      ]),
    ]);
  }
}

class _RowsSheet extends StatelessWidget {
  const _RowsSheet();

  @override
  Widget build(BuildContext context) {
    final songs = _songs(context);
    final current = _current(context);
    final others = songs.where((s) => s != current).take(3).toList();
    final yt = YouTubeSearchResult(
      videoId: 'gallery1',
      title: 'Broken Sun',
      author: 'Monster Siren Records',
      duration: Duration(minutes: 1, seconds: 45),
    );
    final ytLong = YouTubeSearchResult(
      videoId: 'gallery2',
      title: 'Arknights EP - Revealing (Original Soundtrack, Extended Version)',
      author: 'Arknights Official - Yostar',
      duration: Duration(minutes: 4, seconds: 49),
    );
    List<Widget> rowsAt(double w) => [
      for (final s in others)
        SizedBox(
          width: w,
          child: SongTile(song: s),
        ),
      if (current != null)
        SizedBox(
          width: w,
          child: SongTile(song: current, isCurrent: true),
        ),
      SizedBox(
        width: w,
        child: YouTubeSongTile(result: yt),
      ),
      SizedBox(
        width: w,
        child: YouTubeSongTile(result: ytLong),
      ),
    ];
    Widget pair(double w) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Spec(
          'plain',
          PearRowLook(child: Column(children: rowsAt(w))),
          width: w + 20,
        ),
        const SizedBox(width: 30),
        _Spec(
          'with dividers (now)',
          PearRowLook(divided: true, child: Column(children: rowsAt(w))),
          width: w + 20,
        ),
      ],
    );
    return _Sheet([
      _Section('Rows, phone width', [pair(370)]),
      _Section('Rows, 780 window', [pair(400)]),
    ]);
  }
}

class _PanesSheet extends StatelessWidget {
  const _PanesSheet();

  @override
  Widget build(BuildContext context) {
    return _Sheet([
      _Section('Mini player', [
        const _Spec('phone (390)', PlayerBar(), width: 390),
        const _Spec('780 window', PlayerBar(), width: 740),
      ]),
      _Section('Now Playing pane', [
        _Spec(
          'panel (500 x 740)',
          NowPlayingPanel(onCollapse: () {}, onOpenTheater: () {}),
          width: 500,
          height: 740,
        ),
      ]),
    ]);
  }
}

/// A screen rendered at a device size, scaled to fit the sheet.
class _Frame extends StatelessWidget {
  const _Frame(this.label, this.size, this.child, {this.scale = 1});
  final String label;
  final Size size;
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return _Spec(
      label,
      Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white30),
        ),
        child: FittedBox(
          child: SizedBox.fromSize(
            size: size,
            child: MediaQuery(
              data: mq.copyWith(size: size, padding: EdgeInsets.zero),
              child: Stack(
                fit: StackFit.expand,
                children: [const PearBackdrop(), _FrameNavigator(child)],
              ),
            ),
          ),
        ),
      ),
      width: size.width * scale,
      height: size.height * scale,
    );
  }
}

/// Each frame runs its own navigator: a back arrow (or a song opening the
/// player) stays inside the frame, and popping the frame's own screen puts it
/// straight back instead of emptying the gallery window.
class _FrameNavigator extends StatefulWidget {
  const _FrameNavigator(this.child);
  final Widget child;

  @override
  State<_FrameNavigator> createState() => _FrameNavigatorState();
}

class _FrameNavigatorState extends State<_FrameNavigator> {
  var _generation = 0;

  @override
  Widget build(BuildContext context) => Navigator(
    pages: [
      MaterialPage<void>(key: ValueKey(_generation), child: widget.child),
    ],
    onDidRemovePage: (_) => setState(() => _generation++),
  );
}

class _PhoneSheet extends StatelessWidget {
  const _PhoneSheet();

  @override
  Widget build(BuildContext context) => const _Sheet([
    _Section('Phone (390 x 844)', [
      _Frame(
        'library, now (dock, flat rows + dividers)',
        Size(390, 844),
        HomeShell(),
        scale: 0.9,
      ),
      _Frame('player', Size(390, 844), PlayerScreen(), scale: 0.9),
      _Frame(
        'player sideways (844 x 390)',
        Size(844, 390),
        PlayerScreen(),
        scale: 0.9,
      ),
      _Frame('settings', Size(390, 844), SettingsScreen(), scale: 0.9),
      _Frame('sideways (844 x 390)', Size(844, 390), HomeShell(), scale: 0.9),
    ]),
  ]);
}

class _SidewaysSheet extends StatelessWidget {
  const _SidewaysSheet();

  @override
  Widget build(BuildContext context) => const _Sheet([
    _Section('Phone held sideways (844 x 390)', [
      _Frame('shell', Size(844, 390), HomeShell()),
      _Frame('player', Size(844, 390), PlayerScreen()),
    ]),
  ]);
}

class _DesktopSheet extends StatelessWidget {
  const _DesktopSheet();

  @override
  Widget build(BuildContext context) => const _Sheet([
    _Section('Desktop', [
      _Frame('1440 x 860, now', Size(1440, 860), HomeShell(), scale: 0.48),
      _Frame('780 x 900', Size(780, 900), HomeShell(), scale: 0.62),
    ]),
  ]);
}

/// The Windows player: on a desktop the Now Playing pane is the only
/// player (always expanded, Console look under Graphite), shown here beside
/// the library at a small, a normal and a maximized window.
class _PlayersSheet extends StatelessWidget {
  const _PlayersSheet();

  @override
  Widget build(BuildContext context) => const _Sheet([
    _Section('Windows player (Now Playing pane)', [
      _Frame('1100 x 760', Size(1100, 760), HomeShell(), scale: 0.6),
      _Frame('1500 x 900', Size(1500, 900), HomeShell(), scale: 0.5),
      _Frame('maximized 1920 x 1040', Size(1920, 1040), HomeShell(),
          scale: 0.4),
    ]),
  ]);
}

/// Opens one of the app's real dialogs by name.
void _openDialog(BuildContext context, String name) {
  final player = context.read<PlayerService>();
  switch (name) {
    case 'sleep':
      showSleepTimerDialog(context, player);
    case 'speed':
      showPlaybackSpeedDialog(context, player);
    case 'info':
      StreamQualityInfoDialog.show(context);
    case 'lyrics':
      final song = player.currentSong;
      if (song != null) {
        showLyricSyncSheet(context, song: song, player: player);
      }
  }
}

class _ScreensSheet extends StatelessWidget {
  const _ScreensSheet();

  @override
  Widget build(BuildContext context) => _Sheet([
    _Section('Dialogs (open the real ones)', [
      for (final d in const ['sleep', 'speed', 'info', 'lyrics'])
        OutlinedButton(
          onPressed: () => _openDialog(context, d),
          child: Text(d),
        ),
    ]),
    const _Section('Screens (390 x 844)', [
      _Frame('playlists', Size(390, 844), PlaylistsScreen(), scale: 0.9),
      _Frame('history', Size(390, 844), HistoryScreen(), scale: 0.9),
      _Frame('settings', Size(390, 844), SettingsScreen(), scale: 0.9),
    ]),
  ]);
}
