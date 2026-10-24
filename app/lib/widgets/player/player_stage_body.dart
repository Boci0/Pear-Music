import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/lyrics_display.dart';
import '../../services/player_service.dart';
import '../../services/screen_awake.dart';
import '../../services/video_service.dart';
import '../../theme/glass.dart';
import '../pear_app_bar.dart';
import '../song_tile.dart';
import '../tactile_button.dart';
import 'lyric_sync_sheet.dart';
import 'lyrics_view.dart';
import 'playback_speed_dialog.dart';
import 'player_artwork.dart';
import 'player_controls.dart';
import 'player_video_view.dart';
import 'sleep_timer_dialog.dart';
import 'stream_quality_info_dialog.dart';

/// The portrait player: the cover (or video, or lyrics) as large as the
/// screen allows, the title and artist aligned left under it, a thin seek
/// line, the transport and a quiet row of tool icons. The Cover / Video /
/// Lyrics switch sits in the top bar; the pull-up Up Next sheet stays as it
/// is.
class PlayerStageBody extends StatelessWidget {
  final AppController controller;
  final PlayerService player;
  final Song song;
  final Duration duration;
  final Color accent;
  final VoidCallback onOpenQueue;

  const PlayerStageBody({
    super.key,
    required this.controller,
    required this.player,
    required this.song,
    required this.duration,
    required this.accent,
    required this.onOpenQueue,
  });

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return RepaintBoundary(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 62.0 + bottomInset + 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Only this area changes with the view; the seek line, controls
            // and tools stay put.
            Expanded(child: _buildView(context)),
            PlayerSeekBar(player: player, duration: duration, accent: accent),
            PlayerTransport(
              player: player,
              controller: controller,
              accent: accent,
            ),
            const SizedBox(height: 12),
            StageToolsRow(
              player: player,
              controller: controller,
              song: song,
              onOpenQueue: onOpenQueue,
            ),
          ],
        ),
      ),
    );
  }

  /// The cover, the video or the full-height lyrics, faded and eased into
  /// place when the view changes.
  Widget _buildView(BuildContext context) {
    final showVideo = context.watch<VideoService?>()?.showingFor(song) ?? false;
    return ValueListenableBuilder<bool>(
      valueListenable: PlayerArtwork.showLyricsNotifier,
      builder: (context, lyrics, _) {
        final view = PlayerViewTabs.current(lyrics: lyrics, video: showVideo);
        return _ViewStage(
          view: view,
          child: view == PlayerView.lyrics
              ? _buildLyrics()
              : _buildPicture(video: view == PlayerView.video),
        );
      },
    );
  }

  /// Lyrics fill the space; the title block shrinks to one line under them.
  Widget _buildLyrics() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Expanded(
          child: StageLyricsPanel(song: song, player: player, accent: accent),
        ),
        const SizedBox(height: 10),
        StageSongInfo(song: song, accent: accent, compact: true),
      ],
    );
  }

  /// The cover or the video as large as the space allows, the title right
  /// under it, the pair centred in the space.
  Widget _buildPicture({required bool video}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Room for the title block (two title lines and the artist).
        final below = constraints.maxHeight - 96;
        final artSize = math.max(80.0, math.min(constraints.maxWidth, below));
        return Center(
          child: SizedBox(
            width: video ? constraints.maxWidth : artSize,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (video)
                  PlayerVideoView(
                    accent: accent,
                    maxWidth: constraints.maxWidth,
                    maxHeight: math.max(below, 120),
                  )
                else
                  PlayerArtworkHero(
                    song: song,
                    size: artSize,
                    artwork: ArtworkPalette.cachedBytes(song),
                    accent: accent,
                    videoEnabled: true,
                    viewButtons: false,
                  ),
                const SizedBox(height: 16),
                StageSongInfo(song: song, accent: accent),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The player for a phone held sideways: the cover, video or
/// lyrics on the left at the full height, and everything else (close, tabs,
/// title, seek bar, controls, tools) in a column on the right. There is no top
/// bar: [leading] and [trailing] sit either side of the tabs instead.
class PlayerStageLandscapeBody extends StatelessWidget {
  final AppController controller;
  final PlayerService player;
  final Song song;
  final Duration duration;
  final Color accent;
  final VoidCallback onOpenQueue;
  final Widget leading;
  final Widget trailing;

  const PlayerStageLandscapeBody({
    super.key,
    required this.controller,
    required this.player,
    required this.song,
    required this.duration,
    required this.accent,
    required this.onOpenQueue,
    required this.leading,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final showVideo = context.watch<VideoService?>()?.showingFor(song) ?? false;
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 5,
              child: ValueListenableBuilder<bool>(
                valueListenable: PlayerArtwork.showLyricsNotifier,
                builder: (context, lyrics, _) {
                  final view = PlayerViewTabs.current(
                    lyrics: lyrics,
                    video: showVideo,
                  );
                  return _ViewStage(
                    view: view,
                    child: LayoutBuilder(
                      builder: (context, c) => Center(
                        child: view == PlayerView.lyrics
                            ? StageLyricsPanel(
                                song: song,
                                player: player,
                                accent: accent,
                              )
                            : view == PlayerView.video
                            ? PlayerVideoView(
                                accent: accent,
                                maxWidth: c.maxWidth,
                                maxHeight: c.maxHeight,
                              )
                            : PlayerArtworkHero(
                                song: song,
                                size: math.max(
                                  80,
                                  math.min(c.maxWidth, c.maxHeight),
                                ),
                                artwork: ArtworkPalette.cachedBytes(song),
                                accent: accent,
                                videoEnabled: true,
                                viewButtons: false,
                              ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              flex: 5,
              child: LayoutBuilder(
                builder: (context, c) {
                  // Spread over the height; scroll only on a very short
                  // screen.
                  final fits = c.maxHeight >= 320;
                  final column = Column(
                    mainAxisSize: fits ? MainAxisSize.max : MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          leading,
                          Expanded(
                            child: Center(
                              child: PlayerViewTabs(song: song, accent: accent),
                            ),
                          ),
                          trailing,
                        ],
                      ),
                      StageSongInfo(song: song, accent: accent, compact: true),
                      PlayerSeekBar(
                        player: player,
                        duration: duration,
                        accent: accent,
                      ),
                      PlayerTransport(
                        player: player,
                        controller: controller,
                        accent: accent,
                      ),
                      StageToolsRow(
                        player: player,
                        controller: controller,
                        song: song,
                        onOpenQueue: onOpenQueue,
                      ),
                    ],
                  );
                  return fits
                      ? column
                      : SingleChildScrollView(child: column);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which picture the player shows.
enum PlayerView { cover, video, lyrics }

/// Cover / Video / Lyrics as a small pill switch, the selected one filled.
/// Video only appears for a song that has a picture; with a single view left
/// there is nothing to switch and the switch hides.
class PlayerViewTabs extends StatelessWidget {
  final Song song;
  final Color accent;

  /// False leaves Lyrics out (Theater mode shows them in a column of their
  /// own).
  final bool lyrics;

  const PlayerViewTabs({
    super.key,
    required this.song,
    required this.accent,
    this.lyrics = true,
  });

  /// The view on screen now: the lyrics sit on top of either picture.
  static PlayerView current({required bool lyrics, required bool video}) =>
      lyrics
      ? PlayerView.lyrics
      : video
      ? PlayerView.video
      : PlayerView.cover;

  static void select(BuildContext context, PlayerView view) {
    final video = context.read<VideoService?>();
    switch (view) {
      case PlayerView.cover:
        PlayerArtwork.closeLyrics();
        video?.hide();
      case PlayerView.video:
        PlayerArtwork.closeLyrics();
        video?.show();
      case PlayerView.lyrics:
        video?.hide();
        PlayerArtwork.showLyricsNotifier.value = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final videoService = context.watch<VideoService?>();
    final canVideo = videoService?.canOffer(song) ?? false;
    final showingVideo = videoService?.showingFor(song) ?? false;
    return ValueListenableBuilder<bool>(
      valueListenable: PlayerArtwork.showLyricsNotifier,
      builder: (context, showLyrics, _) {
        final selected = current(
          lyrics: lyrics && showLyrics,
          video: showingVideo,
        );
        final views = [
          PlayerView.cover,
          if (canVideo) PlayerView.video,
          if (lyrics) PlayerView.lyrics,
        ];
        if (views.length < 2) return const SizedBox.shrink();
        // Shrinks rather than overflows beside the buttons of a small phone
        // held sideways.
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final view in views)
                  _ViewTab(
                    label: view.name[0].toUpperCase() + view.name.substring(1),
                    selected: view == selected,
                    onTap: () {
                      TactileFeedback.selection();
                      select(context, view);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ViewTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ViewTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: AnimatedContainer(
          duration: _ViewStage.duration,
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}

/// Slides the picked view in from the side of its tab, the old one out the
/// other way, both fading: Lyrics comes in from the right, Cover from the
/// left.
class _ViewStage extends StatefulWidget {
  final PlayerView view;
  final Widget child;

  const _ViewStage({required this.view, required this.child});

  static const Duration duration = Duration(milliseconds: 380);

  @override
  State<_ViewStage> createState() => _ViewStageState();
}

class _ViewStageState extends State<_ViewStage> {
  /// 1 when the new view is to the right of the old one, -1 to the left.
  int _direction = 1;

  @override
  void didUpdateWidget(_ViewStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.view != widget.view) {
      _direction = widget.view.index > oldWidget.view.index ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSwitcher(
        duration: _ViewStage.duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) =>
            Stack(fit: StackFit.expand, children: [...previous, ?current]),
        // A fresh builder each build, so the view on its way out is given
        // the exit side for this switch, not the side it once came in from.
        transitionBuilder: (child, animation) {
          final incoming = child.key == ValueKey(widget.view);
          final side = (incoming ? 0.22 : -0.22) * _direction;
          return SlideTransition(
            position: Tween<Offset>(
              begin: Offset(side, 0),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: KeyedSubtree(key: ValueKey(widget.view), child: widget.child),
      ),
    );
  }
}

/// The title (tap to copy) over the artist, aligned left, and the favourite
/// button on the right.
class StageSongInfo extends StatelessWidget {
  final Song song;
  final Color accent;

  /// One line, no artist: under the full-height lyrics.
  final bool compact;

  const StageSongInfo({
    super.key,
    required this.song,
    required this.accent,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final controller = context.read<AppController>();
    final isFav = context.select<AppController, bool>(
      (c) => c.isFavorite(song.id),
    );
    final connecting = context.select<PlayerService, bool>(
      (p) => p.isBufferingNext,
    );
    final theme = Theme.of(context);
    final muted = Colors.white.withValues(alpha: 0.55);
    final isStream = song.sourceDeviceId == 'stream';
    // The artist, or the connection while a stream starts.
    final subtitle = isStream && connecting
        ? 'Connecting...'
        : (song.artist ?? '');

    return Row(
      crossAxisAlignment: compact
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Expanded(
          child: InkWell(
            mouseCursor: WidgetStateMouseCursor.clickable,
            borderRadius: BorderRadius.circular(6),
            onTap: () => _copyTitle(context, song.title),
            onLongPress: () => _copyTitle(context, song.title),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontSize: compact ? 17 : 22,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                if (subtitle.isNotEmpty && !compact) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: connecting && isStream ? accent : muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        TactileIconButton(
          icon: Icon(
            isFav ? Icons.favorite : Icons.favorite_border,
            color: isFav ? accent : muted,
          ),
          tooltip: isFav ? 'Remove from favorites' : 'Add to favorites',
          onPressed: () => controller.toggleFavorite(song.id, song: song),
        ),
      ],
    );
  }

  static Future<void> _copyTitle(BuildContext context, String title) async {
    await Clipboard.setData(ClipboardData(text: title));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Title copied')));
    }
  }
}

/// Queue, sleep, speed and radio (save to library for a stream) as a quiet
/// row of icons. A running sleep timer or a changed speed lights its icon
/// and shows its value beside it.
class StageToolsRow extends StatelessWidget {
  final PlayerService player;
  final AppController controller;
  final Song song;
  final VoidCallback onOpenQueue;

  const StageToolsRow({
    super.key,
    required this.player,
    required this.controller,
    required this.song,
    required this.onOpenQueue,
  });

  @override
  Widget build(BuildContext context) {
    final speed = context.select<PlayerService, double>((p) => p.speed);
    final isStream = song.sourceDeviceId == 'stream';
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        StageToolIcon(
          icon: Icons.queue_music_rounded,
          tooltip: 'Queue',
          onTap: onOpenQueue,
        ),
        _SleepToolButton(player: player),
        StageToolIcon(
          icon: Icons.speed_rounded,
          tooltip: 'Playback speed',
          active: speed != 1.0,
          caption: speed == 1.0 ? null : '${_speedLabel(speed)}×',
          onTap: () => showPlaybackSpeedDialog(context, player),
        ),
        isStream
            ? StageToolIcon(
                icon: Icons.download_rounded,
                tooltip: 'Save to library',
                onTap: () => controller.saveStreamToLibrary(song),
              )
            : StageToolIcon(
                icon: Icons.sensors_rounded,
                tooltip: 'Start Radio mix',
                onTap: () => controller.startRadio(song),
              ),
      ],
    );
  }

  static String _speedLabel(double speed) {
    final text = speed.toStringAsFixed(2);
    // 1.00 -> 1.0, 1.25 stays, 0.50 -> 0.5.
    return text.endsWith('0') ? text.substring(0, text.length - 1) : text;
  }
}

/// One tool: a plain icon, in the accent while [active], with an optional
/// value beside it.
class StageToolIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final String? caption;

  const StageToolIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.caption,
  });

  @override
  Widget build(BuildContext context) {
    final color = active
        ? Theme.of(context).colorScheme.primary
        : Colors.white.withValues(alpha: 0.7);
    return TactileIconButton(
      tooltip: tooltip,
      padding: const EdgeInsets.all(10),
      onPressed: () {
        TactileFeedback.click();
        onTap();
      },
      icon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: color),
          if (caption != null) ...[
            const SizedBox(width: 6),
            Text(
              caption!,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The sleep icon, with the time left beside it while a sleep timer runs.
class _SleepToolButton extends StatefulWidget {
  final PlayerService player;
  const _SleepToolButton({required this.player});

  @override
  State<_SleepToolButton> createState() => _SleepToolButtonState();
}

class _SleepToolButtonState extends State<_SleepToolButton> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayerChanged);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.player.isSleepTimerActive && mounted) setState(() {});
    });
  }

  void _onPlayerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.player.removeListener(_onPlayerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final remaining = player.sleepTimerRemaining;
    final String? caption;
    if (!player.isSleepTimerActive) {
      caption = null;
    } else if (player.sleepTimerEndOfSong) {
      caption = 'End of song';
    } else if (player.sleepTimerEndOfQueue) {
      caption = 'End of queue';
    } else if (remaining != null) {
      final m = remaining.inMinutes.toString().padLeft(2, '0');
      final s = (remaining.inSeconds % 60).toString().padLeft(2, '0');
      caption = '$m:$s';
    } else {
      caption = null;
    }
    return StageToolIcon(
      icon: Icons.bedtime_outlined,
      tooltip: 'Sleep timer',
      active: player.isSleepTimerActive,
      caption: caption,
      onTap: () => showSleepTimerDialog(context, player),
    );
  }
}

/// The player's more menu: the song's options (add to a playlist, play
/// next, radio, save) and the track info.
class PlayerMoreButton extends StatelessWidget {
  final Song song;
  const PlayerMoreButton({super.key, required this.song});

  @override
  Widget build(BuildContext context) {
    return PearMenuButton<String>(
      tooltip: 'More',
      icon: Icons.more_vert_rounded,
      onSelected: (action) => action == 'info'
          ? StreamQualityInfoDialog.show(context)
          : SongTile.showMenuFor(context, song),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'options', child: Text('Song options')),
        PopupMenuItem(value: 'info', child: Text('Track info')),
      ],
    );
  }
}

/// The full-height lyrics in the player: a rounded panel with every line,
/// following the song, and the Lyrics Options button in its corner.
class StageLyricsPanel extends StatefulWidget {
  final Song song;
  final PlayerService player;
  final Color accent;

  const StageLyricsPanel({
    super.key,
    required this.song,
    required this.player,
    required this.accent,
  });

  @override
  State<StageLyricsPanel> createState() => _StageLyricsPanelState();
}

class _StageLyricsPanelState extends State<StageLyricsPanel> {
  /// Bumped when the options sheet changes the lyrics, to load them again.
  int _version = 0;

  @override
  void initState() {
    super.initState();
    LyricsDisplay.keepScreenOn.addListener(_holdScreen);
    _holdScreen();
  }

  /// Keeps the screen on while the lyrics show, when Lyrics Options allows
  /// it (the cover card did this for the lyrics inside it).
  void _holdScreen() =>
      ScreenAwake.hold(this, mounted && LyricsDisplay.keepScreenOn.value);

  @override
  void dispose() {
    LyricsDisplay.keepScreenOn.removeListener(_holdScreen);
    ScreenAwake.hold(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(
        color: Colors.white.withValues(alpha: PearGlassTokens.edge),
      ),
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: PearGlassTokens.angularPanel,
        shape: shape,
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        // The options sit in their own strip so the lines never run under
        // them.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 44,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ),
              child: TextButton.icon(
                onPressed: () => showLyricSyncSheet(
                  context,
                  song: widget.song,
                  player: widget.player,
                  onLyricsUpdated: () => setState(() => _version++),
                ),
                icon: const Icon(Icons.tune_rounded, size: 15),
                label: const Text('Options', style: TextStyle(fontSize: 13)),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white.withValues(alpha: 0.75),
                ),
              ),
            ),
            Expanded(
              child: ClipRect(
                child: LayoutBuilder(
                  builder: (context, constraints) => LyricsView(
                    key: ValueKey('stage_lyrics_${widget.song.id}_$_version'),
                    song: widget.song,
                    player: widget.player,
                    accent: widget.accent,
                    size: constraints.maxWidth,
                    scrolling: true,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
