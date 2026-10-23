
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/player_service.dart';
import '../services/video_service.dart';
import 'home_shell.dart';
import '../widgets/pear_app_bar.dart';
import '../widgets/player/player_artwork.dart';
import '../widgets/player/player_desktop_body.dart';
import '../widgets/player/player_landscape_body.dart';
import '../widgets/player/player_portrait_body.dart';
import '../widgets/player/playback_speed_dialog.dart';
import '../widgets/player/queue_bottom_sheet.dart';
import '../widgets/player/sleep_timer_dialog.dart';
import '../widgets/player/stream_quality_info_dialog.dart';
import '../widgets/tactile_button.dart';

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

  /// Lay the player out as on a phone whatever the platform, in windows
  /// narrower than 900 (phone sizes): the design gallery (lib/dev) sets it so
  /// its phone frames match a real phone while its desktop frames stay
  /// desktop.
  static bool debugPhoneLayout = false;

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
  bool _handingOffToPane = false;

  /// Kept to stop the picture when this page closes: dispose cannot look it
  /// up, and a picture nobody is looking at would go on fetching.
  VideoService? _video;

  /// When the window grows wide enough for the Now Playing pane (for example
  /// the player was opened at phone width and the window was then widened),
  /// close this page and open the pane's expanded player instead, so wide
  /// windows never show two different players.
  ///
  /// Only this route may be current: while a popup (queue, lyrics options,
  /// speed, sleep timer) sits on top, popping would close that popup instead
  /// of this page and leave the shell showing the full page over an expanded
  /// pane. The hand-off is left for a later build, after the popup is gone.
  void _handOffToPaneIfWide(Size size) {
    if (_handingOffToPane || !HomeShell.usesNowPlayingPane(size)) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _handingOffToPane = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final currentRoute = ModalRoute.of(context);
      if (currentRoute != null && !currentRoute.isCurrent) {
        // A popup opened before this frame: retry on a later build instead of
        // latching the hand-off on a page that is no longer on top.
        _handingOffToPane = false;
        return;
      }
      final navigator = Navigator.of(context);
      if (!navigator.canPop()) {
        _handingOffToPane = false;
        return;
      }
      HomeShell.requestExpandedPane();
      navigator.pop();
    });
  }

  @override
  void initState() {
    super.initState();
    _video = context.read<VideoService?>();
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

  void _openQueueSheet(PlayerService player, Color accent) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 600),
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.9,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: PlayerQueuePanel(player: player, accent: accent),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerService>();
    final controller = context.read<AppController>();
    final song = context.select<PlayerService, Song?>((p) => p.currentSong);
    final duration = context.select<PlayerService, Duration>((p) => p.duration ?? Duration.zero);
    final themePrimary = Theme.of(context).colorScheme.primary;
    _handOffToPaneIfWide(MediaQuery.sizeOf(context));

    if (song != null) {
      _resolveAccent(song, themePrimary);
    }
    final targetAccent = _accentColor ?? themePrimary;

    final phoneDebug = PlayerScreen.debugPhoneLayout &&
        MediaQuery.sizeOf(context).width < 900;
    final isDesktopPlatform = !phoneDebug &&
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    // Desktop windows keep the two-column split body once they are wide
    // enough; phones keep using orientation so landscape phones get the split
    // body too.
    final landscape = isDesktopPlatform
        ? MediaQuery.sizeOf(context).width >= 900
        : MediaQuery.orientationOf(context) == Orientation.landscape;
    // Very wide desktop windows trade the pull-up queue peek for a permanent
    // Up Next panel beside the controls.
    final useQueuePanel =
        isDesktopPlatform && MediaQuery.sizeOf(context).width >= 1250;
    // The expandable queue peek stays available on wide desktop windows even
    // though they use the landscape body.
    final showQueuePeek = (!landscape || isDesktopPlatform) && !useQueuePanel;
    // A phone held sideways or a car screen or tablet (under 700 dp tall): the title and
    // song buttons go up into the top bar and the card takes the whole height.
    final compactLandscape =
        landscape && !useQueuePanel && MediaQuery.sizeOf(context).height < 700;

    final phoneLandscape =
        (phoneDebug ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS) &&
        MediaQuery.orientationOf(context) == Orientation.landscape;

    final appBar = AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      notificationPredicate: (_) => false,
      titleSpacing: 0,
      title: compactLandscape && song != null
          ? PlayerSongInfo(song: song, compact: true)
          : null,
      leading: BackButton(
        onPressed: () {
          TactileFeedback.click();
          if (_sheetController.progress > 0.001) {
            _sheetController.collapse();
          } else {
            // The lyrics are parked in dispose(), after the close
            // animation: switching them off here would swap the artwork in
            // the middle of the transition.
            Navigator.of(context).pop();
          }
        },
      ),
      actions: [
        PlaybackSpeedButton(player: player),
        SleepTimerButton(player: player),
        StreamQualityInfoButton(player: player),
        const SizedBox(width: kAppBarActionInset),
      ],
    );

    if (song == null) {
      return Scaffold(
        key: _scaffoldKey,
        appBar: appBar,
        body: const Center(child: Text('Nothing is playing')),
      );
    }


    // Theme the player around the song's artwork: extract a dominant colour
    // (async, cached per song) and smoothly animate the accent when the track
    // changes.
    return ListenableBuilder(
      listenable: _sheetController,
      builder: (context, child) {
        final isCollapsed = _sheetController.progress <= 0.001;
        return PopScope(
          canPop: isCollapsed,
          onPopInvokedWithResult: (didPop, result) {
            // A completed pop parks the lyrics in dispose().
            if (didPop) return;
            if (_sheetController.progress > 0.001) {
              _sheetController.collapse();
            } else {
              Navigator.of(context).pop();
            }
          },
          child: child!,
        );
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
                                  child: useQueuePanel
                                      ? PlayerDesktopBody(
                                          controller: controller,
                                          player: player,
                                          song: song,
                                          duration: duration,
                                          accent: targetAccent,
                                          panelWidth: (MediaQuery.sizeOf(
                                                      context)
                                                  .width *
                                              0.28)
                                              .clamp(340.0, 440.0),
                                        )
                                      : PlayerLandscapeBody(
                                          controller: controller,
                                          player: player,
                                          song: song,
                                          duration: duration,
                                          accent: targetAccent,
                                          // A phone held sideways has neither
                                          // the pull-up sheet nor the panel.
                                          compact: compactLandscape,
                                          onOpenQueue: phoneLandscape
                                              ? () => _openQueueSheet(
                                                  player, targetAccent)
                                              : null,
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
                if (showQueuePeek)
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
                if (showQueuePeek)
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
                          child: Center(
                            child: ConstrainedBox(
                              constraints:
                                  const BoxConstraints(maxWidth: 760),
                              child: ExpandableQueueSheet(
                                player: player,
                                controller: controller,
                                accent: targetAccent,
                                minChildSize: minChildSize,
                                peekHeight: peekHeight,
                                maxHeight: maxHeight,
                                sheetController: _sheetController,
                              ),
                            ),
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
    // Park the lyrics now that the close animation is over. Deferred to a
    // microtask: the widget tree is locked during dispose, and the Now
    // Playing pane (after a hand-off to a wide window) listens to the lyrics
    // switch. The visualizer is a setting and stays on.
    Future.microtask(PlayerArtwork.closeLyrics);
    final video = _video;
    Future.microtask(() => video?.hide());
    super.dispose();
  }
}