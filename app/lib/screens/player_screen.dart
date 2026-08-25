import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/player_service.dart';
import '../widgets/player/player_drawer.dart';
import '../widgets/player/player_landscape_body.dart';
import '../widgets/player/player_portrait_body.dart';
import '../widgets/player/player_wide_body.dart';
import '../widgets/player/sleep_timer_dialog.dart';

/// Full-screen player with seek bar, transport controls, sleep timer, and
/// volume.
///
/// Responsive across three screen widths:
///   - **Wide (desktop, >= 900px)**: 2-column layout (showcase on the left,
///     interactive queue/playlists + controls on the right).
///   - **Mobile portrait**: vertically stacked player.
///   - **Mobile landscape**: 2-column split (artwork/info + controls).
///
/// On mobile, a hamburger menu in the top-right opens a drawer that browses
/// Playlists and Songs from the player screen.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  /// When set, the wide layout or mobile drawer shows this playlist''s songs
  /// instead of all library songs.
  String? _activePlaylistId;

  /// Opens the library drawer from the app-bar menu. A key is required because
  /// Scaffold.of(context) from inside this Scaffold would resolve to the
  /// HomeShell''s Scaffold (which has no drawer) and silently do nothing.
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  Color? _accentColor;
  String? _resolvedSongId;

  @override
  void initState() {
    super.initState();
    final player = context.read<PlayerService>();
    if (player.queueSourceId != null &&
        player.queueSourceId!.startsWith('playlist:')) {
      _activePlaylistId = player.queueSourceId!.substring('playlist:'.length);
    }
  }

  void _resolveAccent(Song song, Color themePrimary) {
    if (_resolvedSongId == song.id) return;
    _resolvedSongId = song.id;
    if (song.artwork == null || song.artwork!.isEmpty) {
      _accentColor = themePrimary;
      return;
    }
    final fallbackTarget = _accentColor ?? themePrimary;
    _accentColor = ArtworkPalette.dominantSync(
      song,
      fallbackColor: fallbackTarget,
    );
    ArtworkPalette.dominant(song, fallbackColor: themePrimary).then((color) {
      if (mounted && _resolvedSongId == song.id && _accentColor != color) {
        setState(() => _accentColor = color);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final controller = context.read<AppController>();
    final song = player.currentSong;
    final isWide = MediaQuery.sizeOf(context).width >= 900;
    final themePrimary = Theme.of(context).colorScheme.primary;

    final appBar = AppBar(
      title: isWide ? const Text('Now Playing') : null,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      notificationPredicate: (_) => false,
      leading: const BackButton(),
      actions: [
        SleepTimerButton(player: player),
        if (!isWide)
          IconButton(
            tooltip: 'Library',
            icon: const Icon(Icons.menu),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
      ],
    );

    if (song == null) {
      return Scaffold(
        key: _scaffoldKey,
        appBar: appBar,
        body: const Center(child: Text('Nothing is playing')),
      );
    }

    _resolveAccent(song, themePrimary);
    final targetAccent = _accentColor ?? themePrimary;

    final duration = player.duration ?? Duration.zero;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    // Theme the player around the song's artwork: extract a dominant colour
    // (async, cached per song) and smoothly animate the accent when the track
    // changes.
    return Scaffold(
      key: _scaffoldKey,
      appBar: appBar,
      drawer: isWide
          ? null
          : PlayerDrawer(
              controller: controller,
              player: player,
              currentSong: song,
              activePlaylistId: _activePlaylistId,
              onActivePlaylistChanged: (id) =>
                  setState(() => _activePlaylistId = id),
            ),
      body: TweenAnimationBuilder<Color?>(
        tween: ColorTween(
          end: targetAccent,
        ),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
        builder: (context, animColor, _) {
          final activeAccent = animColor ?? targetAccent;
          return SafeArea(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: isWide
                  ? PlayerWideBody(
                      controller: controller,
                      player: player,
                      song: song,
                      duration: duration,
                      accent: activeAccent,
                      activePlaylistId: _activePlaylistId,
                      onActivePlaylistChanged: (id) =>
                          setState(() => _activePlaylistId = id),
                    )
                  : landscape
                      ? PlayerLandscapeBody(
                          controller: controller,
                          player: player,
                          song: song,
                          duration: duration,
                          accent: activeAccent,
                        )
                      : PlayerPortraitBody(
                          controller: controller,
                          player: player,
                          song: song,
                          duration: duration,
                          accent: activeAccent,
                        ),
            ),
          );
        },
      ),
    );
  }
}