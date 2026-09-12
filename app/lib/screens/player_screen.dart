import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/player_service.dart';
import '../widgets/player/player_artwork.dart';
import '../widgets/player/player_console_dialog.dart';
import '../widgets/player/player_landscape_body.dart';
import '../widgets/player/player_portrait_body.dart';
import '../widgets/player/queue_bottom_sheet.dart';
import '../widgets/player/sleep_timer_dialog.dart';
import '../widgets/player/stream_quality_info_dialog.dart';

/// Full-screen player with seek bar, transport controls, sleep timer, and
/// volume.
///
/// Responsive across screen orientations:
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
  /// Opens the library drawer from the app-bar menu. A key is required because
  /// Scaffold.of(context) from inside this Scaffold would resolve to the
  /// HomeShell's Scaffold (which has no drawer) and silently do nothing.
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final QueueSheetController _sheetController = QueueSheetController();

  Color? _accentColor;
  String? _resolvedSongId;

  @override
  void initState() {
    super.initState();
    ArtworkPalette.paletteNotifier.addListener(_onPaletteUpdated);
  }

  void _onPaletteUpdated() {
    if (!mounted) return;
    final song = context.read<PlayerService>().currentSong;
    if (song != null && ArtworkPalette.hasResolved(song)) {
      final color = ArtworkPalette.dominantSync(song);
      if (_accentColor != color) {
        setState(() => _accentColor = color);
      }
    }
  }

  void _resolveAccent(Song song, Color themePrimary) {
    final isResolved = ArtworkPalette.hasResolved(song);
    if (_resolvedSongId == song.id && isResolved) return;
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
    final player = context.read<PlayerService>();
    final controller = context.read<AppController>();
    final song = context.select<PlayerService, Song?>((p) => p.currentSong);
    final duration = context.select<PlayerService, Duration>((p) => p.duration ?? Duration.zero);
    final themePrimary = Theme.of(context).colorScheme.primary;

    if (song != null) {
      _resolveAccent(song, themePrimary);
    }
    final targetAccent = _accentColor ?? themePrimary;

    final appBar = AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      notificationPredicate: (_) => false,
      leading: const BackButton(),
      actions: [
        IconButton(
          tooltip: 'Diagnostics Console',
          icon: const Icon(Icons.terminal_rounded),
          onPressed: () => PlayerConsoleDialog.show(context),
        ),
        SleepTimerButton(player: player),
        StreamQualityInfoButton(player: player),
      ],
    );

    if (song == null) {
      return Scaffold(
        key: _scaffoldKey,
        appBar: appBar,
        body: const Center(child: Text('Nothing is playing')),
      );
    }

    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    // Theme the player around the song's artwork: extract a dominant colour
    // (async, cached per song) and smoothly animate the accent when the track
    // changes.
    return PopScope(
      canPop: _sheetController.progress <= 0.001,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _sheetController.progress > 0.001) {
          _sheetController.collapse();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: TweenAnimationBuilder<Color?>(
          tween: ColorTween(
            begin: targetAccent,
            end: targetAccent,
          ),
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeInOutCubic,
          builder: (context, animColor, child) {
            final activeAccent = animColor ?? targetAccent;
            final washColor = ArtworkPalette.wash(activeAccent, lightness: 0.09);

            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                gradient: RadialGradient(
                  center: const Alignment(0, -0.35),
                  radius: 1.25,
                  colors: [
                    activeAccent.withValues(alpha: 0.22),
                    washColor.withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
              child: child,
            );
          },
          child: RepaintBoundary(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Column(
                    children: [
                      appBar,
                      Expanded(
                        child: SafeArea(
                          top: false,
                          bottom: false,
                          child: landscape
                              ? Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 24, vertical: 8),
                                  child: PlayerLandscapeBody(
                                    controller: controller,
                                    player: player,
                                    song: song,
                                    duration: duration,
                                    accent: targetAccent,
                                  ),
                                )
                              : PlayerPortraitBody(
                                  controller: controller,
                                  player: player,
                                  song: song,
                                  duration: duration,
                                  accent: targetAccent,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Dimming Scrim when queue is expanded (tap outside to collapse)
                // Covers the full player screen from top to bottom so the top glow
                // and app bar dim seamlessly without any horizontal cutoff boundary.
                if (!landscape)
                  Positioned.fill(
                    child: ListenableBuilder(
                      listenable: _sheetController,
                      builder: (context, _) {
                        final progress = _sheetController.progress;

                        return IgnorePointer(
                          ignoring: progress <= 0.001,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _sheetController.collapse,
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.55 * progress),
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                // YouTube Music style real-time expandable queue sheet
                if (!landscape)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final totalHeight = MediaQuery.sizeOf(context).height;
                        final bottomInset = MediaQuery.paddingOf(context).bottom;
                        final peekHeight = 62.0 + bottomInset;
                        final minChildSize = (peekHeight / totalHeight).clamp(0.06, 0.22);
                        final maxHeight = (totalHeight * 0.50).clamp(peekHeight, totalHeight * 0.50);

                        return RepaintBoundary(
                          child: ExpandableQueueSheet(
                            player: player,
                            controller: controller,
                            accent: targetAccent,
                            minChildSize: minChildSize,
                            peekHeight: peekHeight,
                            maxHeight: maxHeight,
                            sheetController: _sheetController,
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    ArtworkPalette.paletteNotifier.removeListener(_onPaletteUpdated);
    _sheetController.dispose();
    PlayerArtwork.closeLyrics();
    super.dispose();
  }
}