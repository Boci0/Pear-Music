import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/artwork_service.dart';
import '../services/player_service.dart';
import '../services/video_service.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';
import 'player/playback_speed_dialog.dart';
import 'player/player_artwork.dart';
import 'player/console_parts.dart';
import 'player/lyrics_view.dart';
import 'player/player_controls.dart';
import 'player/player_stage_body.dart';
import 'player/player_video_view.dart';
import 'player/sleep_timer_dialog.dart';
import 'live_seek_bar.dart';
import 'tactile_button.dart';

/// The wide shell's player panel: a header with the Cover / Video switch and
/// the song's tools, the cover (click for Theater mode), song info, seek
/// line, transport, volume and Up next / Lyrics tabs, pinned to the right of
/// the window.
class NowPlayingPanel extends StatelessWidget {
  /// Folds the panel into [NowPlayingStrip].
  final VoidCallback onCollapse;

  /// Clicking the cover opens Theater mode.
  final VoidCallback onOpenTheater;

  const NowPlayingPanel({
    super.key,
    required this.onCollapse,
    required this.onOpenTheater,
  });

  /// Width of the collapsed strip, gutter not included.
  static const double stripWidth = 76;

  /// Shared by the shell's width animation and the panel, so the pane grows
  /// as one motion.
  static const Duration expandTransitionDuration = Duration(milliseconds: 220);

  /// The pane card's docked width. The pane lays its content out at the final
  /// width for the whole animation, so a width change only moves the card's
  /// clip edge (see [_PaneLayoutWidth]).
  static const double expandedPaneWidth = 508;

  /// The card's width while it shows a song's video: half the window, within
  /// a range that keeps both the video and the page beside it usable.
  static double videoPaneWidthFor(double windowWidth) =>
      (windowWidth * 0.5).clamp(640.0, 860.0);

  /// The card's border (one per side); the content area is inset by it.
  static const double _kPaneBorder = 1;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final song = player.currentSong;
    final theme = Theme.of(context);
    final showVideo =
        context.watch<VideoService?>()?.showingFor(song) ?? false;
    final width = showVideo
        ? videoPaneWidthFor(MediaQuery.sizeOf(context).width)
        : expandedPaneWidth;

    return PearGlass(
      key: const ValueKey('now_playing_panel'),
      child: Padding(
        // Inset by the rim so the content keeps the width it is laid out for
        // (see [_kPaneBorder]).
        padding: const EdgeInsets.all(_kPaneBorder),
        child: song == null
          ? _buildEmptyState(theme)
          : _PaneLayoutWidth(
              width: width - 2 * _kPaneBorder,
              child: _buildExpandedState(
                context,
                player,
                song,
                theme,
                showVideo: showVideo,
              ),
            ),
      ),
    );
  }

  /// The player: cover, song info, transport, seek bar and volume, with Up
  /// next and Lyrics tabs under them.
  Widget _buildExpandedState(
    BuildContext context,
    PlayerService player,
    Song song,
    ThemeData theme, {
    required bool showVideo,
  }) {
    final controller = context.read<AppController>();
    final accent = ArtworkPalette.dominantSync(song);
    final control = ArtworkPalette.controlAccent(accent);

    final column = Column(
      key: const ValueKey('now_playing_panel_expanded'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 8, 0),
          child: Row(
            children: [
              const SizedBox(width: 10),
              PlayerViewTabs(song: song, accent: accent, lyrics: false),
              const Spacer(),
              PlaybackSpeedButton(player: player),
              SleepTimerButton(player: player),
              if (song.sourceDeviceId == 'stream')
                TactileIconButton(
                  icon: const Icon(Icons.download_rounded),
                  tooltip: 'Save to library',
                  onPressed: () => controller.saveStreamToLibrary(song),
                )
              else
                TactileIconButton(
                  icon: const Icon(Icons.sensors_rounded),
                  tooltip: 'Start Radio mix',
                  onPressed: () => controller.startRadio(song),
                ),
              PlayerMoreButton(song: song),
              TactileIconButton(
                key: const ValueKey('pane_fold'),
                iconSize: 20,
                icon: const Icon(Icons.chevron_right_rounded),
                tooltip: 'Collapse panel',
                onPressed: onCollapse,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showQueue = !showVideo;
              // The player block takes what it needs and the queue gets the
              // rest, so no empty band opens between the seek bar and volume.
              // The artwork is the part that flexes: it gives way first so
              // the queue keeps room for about five rows (44 each plus its
              // header), and never drops below three.
              final queueMin = showQueue ? 132.0 : 0.0;
              final queueRoom = showQueue ? 262.0 : 0.0;
              final artSize = math
                  .min(
                    constraints.maxWidth - 44,
                    math.min(
                      constraints.maxHeight * 0.54,
                      // Info, seek line, transport and volume under the cover.
                      constraints.maxHeight - queueRoom - 300,
                    ),
                  )
                  .clamp(140.0, 520.0);
              final lineWidth = showVideo ? constraints.maxWidth - 44 : artSize;
              final block = ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight - queueMin,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            const SizedBox(height: 12),
                            PlayerPictureSwap(
                              video: showVideo,
                              child: showVideo
                                  ? PlayerVideoView(
                                      accent: accent,
                                      maxWidth: constraints.maxWidth - 44,
                                      maxHeight: constraints.maxHeight * 0.6,
                                    )
                                  : MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      child: GestureDetector(
                                        key: const ValueKey('pane_theater'),
                                        onTap: onOpenTheater,
                                        child: Tooltip(
                                          message: 'Theater mode',
                                          child: PlayerArtworkHero(
                                            song: song,
                                            size: artSize,
                                            artwork: ArtworkPalette.cachedBytes(
                                              song,
                                            ),
                                            accent: accent,
                                            viewButtons: false,
                                          ),
                                        ),
                                      ),
                                    ),
                            ),
                            const SizedBox(height: 14),
                            // Title and seek line line up with the cover's
                            // edges.
                            SizedBox(
                              width: lineWidth,
                              child: StageSongInfo(song: song, accent: accent),
                            ),
                            const SizedBox(height: 6),
                            SizedBox(
                              width: lineWidth,
                              child: PlayerSeekBar(
                                player: player,
                                duration: player.duration ?? Duration.zero,
                                accent: accent,
                              ),
                            ),
                            const SizedBox(height: 4),
                            PlayerTransport(
                              player: player,
                              controller: controller,
                              accent: accent,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Volume stays outside the scroll area: at shorter window
                    // heights it used to end up below the fold with no
                    // scrollbar cue, which read as a missing control.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
                      child: PlayerVolumeRow(accent: control),
                    ),
                  ],
                ),
              );
              return Column(
                children: [
                  block,
                  if (showQueue)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: _UpNextOrLyrics(
                          player: player,
                          song: song,
                          accent: accent,
                          theme: theme,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                ],
              );
            },
          ),
        ),
      ],
    );
    if (!showVideo || player.queue.isEmpty) return column;

    // Widened for a picture: the queue stands beside the player at full
    // height instead of under it, where it had room for three rows.
    final paneWidth = videoPaneWidthFor(MediaQuery.sizeOf(context).width);
    return Row(
      children: [
        Expanded(child: column),
        SizedBox(
          width: (paneWidth * 0.38).clamp(250.0, 320.0),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
            child: _QueueContextList(
              player: player,
              control: Theme.of(context).colorScheme.primary,
              theme: theme,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.music_note_rounded,
              size: 42,
              color: Colors.white.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 12),
            Text(
              'Nothing playing',
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Pick a song to start listening',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Up next and Lyrics as tabs over the space under the
/// controls, the queue or the synced lyrics in it.
class _UpNextOrLyrics extends StatefulWidget {
  final PlayerService player;
  final Song song;
  final Color accent;
  final ThemeData theme;

  const _UpNextOrLyrics({
    required this.player,
    required this.song,
    required this.accent,
    required this.theme,
  });

  @override
  State<_UpNextOrLyrics> createState() => _UpNextOrLyricsState();
}

class _UpNextOrLyricsState extends State<_UpNextOrLyrics> {
  bool _lyrics = false;

  Widget _tab(String label, bool selected, VoidCallback onTap) => Expanded(
    child: InkWell(
      mouseCursor: WidgetStateMouseCursor.clickable,
      onTap: onTap,
      child: Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: 2,
              color: selected ? widget.accent : Colors.transparent,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected
                ? Colors.white
                : Colors.white.withValues(alpha: 0.55),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
            ),
          ),
          child: Row(
            children: [
              _tab('Up next', !_lyrics, () => setState(() => _lyrics = false)),
              _tab('Lyrics', _lyrics, () => setState(() => _lyrics = true)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _lyrics
              ? LyricsView(
                  key: ValueKey('pane_lyrics_${widget.song.id}'),
                  song: widget.song,
                  player: widget.player,
                  accent: widget.accent,
                  size: 300,
                  scrolling: true,
                )
              : widget.player.queue.isEmpty
              ? Center(
                  child: Text(
                    'Nothing queued',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                )
              : _QueueContextList(
                  player: widget.player,
                  control: widget.theme.colorScheme.primary,
                  theme: widget.theme,
                ),
        ),
      ],
    );
  }
}

/// The player panel folded to a slim strip on the window's
/// right edge: expand, the cover (its tooltip names the song), previous,
/// play or pause, next, and a vertical progress line to click or drag.
class NowPlayingStrip extends StatelessWidget {
  /// Opens the full player: the panel when there is room, else Theater.
  final VoidCallback onExpand;

  const NowPlayingStrip({super.key, required this.onExpand});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final controller = context.read<AppController>();
    final song = player.currentSong;
    final accent = song == null
        ? Theme.of(context).colorScheme.primary
        : ArtworkPalette.controlAccent(ArtworkPalette.dominantSync(song));
    return PearGlass(
      key: const ValueKey('now_playing_strip'),
      child: Column(
        children: [
          const SizedBox(height: 10),
          TactileIconButton(
            key: const ValueKey('pane_unfold'),
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: 'Expand player panel',
            onPressed: onExpand,
          ),
          if (song != null) ...[
            const SizedBox(height: 8),
            Tooltip(
              key: const ValueKey('strip_cover'),
              message: song.title,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onExpand,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: _Artwork(song: song, cacheWidth: 96),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            TactileIconButton(
              tooltip: 'Previous',
              icon: Icon(Icons.skip_previous_rounded, color: accent),
              onPressed: () => controller.previousTrack(),
            ),
            TactileIconButton(
              tooltip: player.playing ? 'Pause' : 'Play',
              icon: Icon(
                player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: accent,
              ),
              iconSize: 28,
              onPressed: () => controller.togglePlayback(),
            ),
            TactileIconButton(
              tooltip: 'Next',
              icon: Icon(Icons.skip_next_rounded, color: accent),
              onPressed: () => controller.nextTrack(),
            ),
            const SizedBox(height: 12),
            Flexible(child: _StripSeekLine(player: player, color: accent)),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

/// The strip's progress, a thin vertical line filling from the bottom.
/// Click or drag along it to seek, like the panel's line: it follows the
/// drag and seeks on release. It thickens under the pointer.
class _StripSeekLine extends StatefulWidget {
  final PlayerService player;
  final Color color;

  const _StripSeekLine({required this.player, required this.color});

  @override
  State<_StripSeekLine> createState() => _StripSeekLineState();
}

class _StripSeekLineState extends State<_StripSeekLine> {
  bool _hovered = false;

  /// The dragged-to fraction; null when not dragging.
  double? _drag;

  int get _totalMs => widget.player.duration?.inMilliseconds ?? 0;

  double _at(double dy, double height) => (1 - dy / height).clamp(0.0, 1.0);

  Duration _to(double f) => Duration(milliseconds: (f * _totalMs).round());

  void _scrub(double f) {
    setState(() => _drag = f);
    widget.player.setScrubbingPosition(_to(f));
  }

  void _commit(double f) {
    widget.player.seek(_to(f));
    widget.player.setScrubbingPosition(null);
    setState(() => _drag = null);
  }

  void _cancel() {
    widget.player.setScrubbingPosition(null);
    setState(() => _drag = null);
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 160),
      child: LayoutBuilder(
        builder: (context, box) {
          final h = box.maxHeight;
          // Live streams have no length to seek in.
          final seekable = _totalMs > 0;
          final thick = _hovered || _drag != null;
          return MouseRegion(
            cursor: seekable ? SystemMouseCursors.click : MouseCursor.defer,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              key: const ValueKey('strip_seek'),
              behavior: HitTestBehavior.opaque,
              onTapUp: seekable
                  ? (d) => _commit(_at(d.localPosition.dy, h))
                  : null,
              onVerticalDragStart: seekable
                  ? (d) => _scrub(_at(d.localPosition.dy, h))
                  : null,
              onVerticalDragUpdate: seekable
                  ? (d) => _scrub(_at(d.localPosition.dy, h))
                  : null,
              onVerticalDragEnd: seekable ? (_) => _commit(_drag ?? 0) : null,
              onVerticalDragCancel: seekable ? _cancel : null,
              // A 28 px wide target around the thin line.
              child: SizedBox(
                width: 28,
                height: h,
                // Ticks while playing: its own layer.
                child: RepaintBoundary(
                  child: StreamBuilder<Duration>(
                    stream: widget.player.uiPositionStream,
                    initialData: widget.player.position ?? Duration.zero,
                    builder: (context, snapshot) {
                      final at = snapshot.data?.inMilliseconds ?? 0;
                      final fraction = _drag ??
                          (seekable ? (at / _totalMs).clamp(0.0, 1.0) : 0.0);
                      final width = thick ? 5.0 : 3.0;
                      return Center(
                        child: Container(
                          width: width,
                          alignment: Alignment.bottomCenter,
                          color: Colors.white.withValues(alpha: 0.18),
                          child: FractionallySizedBox(
                            heightFactor: fraction,
                            child: Container(width: width, color: widget.color),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The compact pane's progress line. Click or drag anywhere along it to seek,
/// the same way as the full player's seek bar: the time label follows the
/// drag and the seek happens on release.
class _ProgressLine extends StatefulWidget {
  final PlayerService player;
  final Color color;
  final ThemeData theme;

  const _ProgressLine({
    required this.player,
    required this.color,
    required this.theme,
  });

  @override
  State<_ProgressLine> createState() => _ProgressLineState();
}

class _ProgressLineState extends State<_ProgressLine> {
  bool _hovered = false;

  /// Where a drag currently points, in milliseconds; null when not dragging.
  double? _dragMs;

  static String _formatTime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
    return '$m:$ss';
  }

  double _msAt(double dx, double width, double totalMs) =>
      (dx / width).clamp(0.0, 1.0) * totalMs;

  void _scrub(double ms) {
    setState(() => _dragMs = ms);
    widget.player.setScrubbingPosition(Duration(milliseconds: ms.round()));
  }

  void _commit(double ms) {
    widget.player.seek(Duration(milliseconds: ms.round()));
    widget.player.setScrubbingPosition(null);
    setState(() => _dragMs = null);
  }

  void _cancel() {
    widget.player.setScrubbingPosition(null);
    setState(() => _dragMs = null);
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final color = widget.color;
    final timeStyle = widget.theme.textTheme.labelSmall?.copyWith(
      fontSize: 10.5,
      color: Colors.white.withValues(alpha: 0.5),
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    // A live stream has no length: the bar spans the history YouTube keeps.
    if (player.isLive) {
      return LiveSeekBar(
        player: player,
        color: color,
        style: timeStyle,
        compact: true,
      );
    }

    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      initialData: player.duration,
      builder: (context, durSnapshot) {
        final total = durSnapshot.data ?? player.duration ?? Duration.zero;
        final totalMs = total.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: player.uiPositionStream,
          initialData: player.position ?? Duration.zero,
          builder: (context, posSnapshot) {
            final playing =
                posSnapshot.data ?? player.position ?? Duration.zero;
            final pos = _dragMs != null
                ? Duration(milliseconds: _dragMs!.round())
                : playing;
            final fraction = totalMs <= 0
                ? 0.0
                : (pos.inMilliseconds / totalMs).clamp(0.0, 1.0);
            final active = _hovered || _dragMs != null;
            return Row(
              children: [
                Text(_formatTime(pos), style: timeStyle),
                const SizedBox(width: 8),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      final canSeek = totalMs > 0 && width > 0;
                      return MouseRegion(
                        cursor: canSeek
                            ? SystemMouseCursors.click
                            : MouseCursor.defer,
                        onEnter: (_) => setState(() => _hovered = true),
                        onExit: (_) => setState(() => _hovered = false),
                        child: GestureDetector(
                          key: const ValueKey('pane_progress'),
                          behavior: HitTestBehavior.opaque,
                          onTapUp: canSeek
                              ? (d) => _commit(
                                  _msAt(d.localPosition.dx, width, totalMs),
                                )
                              : null,
                          onHorizontalDragStart: canSeek
                              ? (d) => _scrub(
                                  _msAt(d.localPosition.dx, width, totalMs),
                                )
                              : null,
                          onHorizontalDragUpdate: canSeek
                              ? (d) => _scrub(
                                  _msAt(d.localPosition.dx, width, totalMs),
                                )
                              : null,
                          onHorizontalDragEnd: canSeek
                              ? (_) => _commit(
                                  _dragMs ?? playing.inMilliseconds.toDouble(),
                                )
                              : null,
                          onHorizontalDragCancel: canSeek ? _cancel : null,
                          // A taller hit area than the 4 px line, so it is
                          // easy to grab.
                          child: SizedBox(
                            height: 18,
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.centerLeft,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(2),
                                  child: SizedBox(
                                    height: active ? 5 : 4,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        ColoredBox(
                                          color: Colors.white.withValues(
                                            alpha: 0.08,
                                          ),
                                        ),
                                        FractionallySizedBox(
                                          alignment: Alignment.centerLeft,
                                          widthFactor: fraction,
                                          child: ColoredBox(color: color),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (active && canSeek)
                                  Positioned(
                                    left: fraction * width - 5,
                                    child: Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        color: color,
                                        shape: BoxShape.rectangle,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text(_formatTime(total), style: timeStyle),
              ],
            );
          },
        );
      },
    );
  }
}

class _Artwork extends StatelessWidget {
  final Song song;

  /// Decode width for the remote cover, in physical pixels.
  final int cacheWidth;

  const _Artwork({required this.song, required this.cacheWidth});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(PearGlassTokens.r(16)),
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primaryContainer,
            theme.colorScheme.primary.withValues(alpha: 0.6),
          ],
        ),
      ),
      child: Icon(
        Icons.music_note_rounded,
        color: theme.colorScheme.onPrimaryContainer,
        size: 56,
      ),
    );

    final artwork = song.artwork;
    Widget image;
    if (artwork == null || artwork.isEmpty) {
      image = placeholder;
    } else if (artwork.startsWith('http')) {
      image = Image.network(
        ArtworkService.optimizeArtworkUrl(artwork),
        cacheWidth: cacheWidth,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => placeholder,
      );
    } else {
      final cached = ArtworkPalette.cachedBytes(song);
      image = FutureBuilder<Uint8List?>(
        initialData: cached,
        future: ArtworkPalette.bytesAsync(song),
        builder: (context, snapshot) {
          final bytes = snapshot.data ?? cached;
          if (bytes == null || bytes.isEmpty) return placeholder;
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
          );
        },
      );
    }

    final radius = BorderRadius.circular(PearGlassTokens.r(PearRadius.sheet - 4));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.30),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: ClipRRect(borderRadius: radius, child: image),
      ),
    );
  }
}

/// Compact "Up Next" list under the pane controls: the next few queue tracks,
/// tappable, the way classic desktop sidebars show what is coming.
/// The pane's queue view: the whole queue with the playing track marked, so
/// finished tracks do not just vanish off the top and the position in the
/// queue is always readable. Follows the playing row with an auto-scroll.
class _QueueContextList extends StatefulWidget {
  final PlayerService player;
  final Color control;
  final ThemeData theme;

  const _QueueContextList({
    required this.player,
    required this.control,
    required this.theme,
  });

  @override
  State<_QueueContextList> createState() => _QueueContextListState();
}

class _QueueContextListState extends State<_QueueContextList> {
  static const double _rowExtent = 44;

  final ScrollController _scrollController = ScrollController();
  int? _lastIndex;
  String? _lastSongId;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// The playing row, resolved by song identity the same way the queue sheet
  /// does. The player's queueIndex getter also syncs itself, but resolving
  /// from [Song.id] keeps the indicator correct even when the queue and the
  /// index disagree.
  int _playingIndex(List<Song> queue) {
    final songId = widget.player.currentSong?.id;
    if (songId == null) return widget.player.queueIndex;
    return queue.indexWhere((s) => s.id == songId);
  }

  /// Keeps the playing track in view as the queue advances: jump on the first
  /// build, animate on track changes, and only when the track actually changes
  /// (the player notifies on every position tick).
  void _syncScrollToCurrent() {
    final queue = widget.player.queue;
    final index = _playingIndex(queue);
    final songId = widget.player.currentSong?.id;
    if (index < 0) return;
    if (index == _lastIndex && songId == _lastSongId) return;
    final animate = _lastIndex != null;
    _lastIndex = index;
    _lastSongId = songId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final target =
          (index * _rowExtent - position.viewportDimension / 2 + _rowExtent / 2)
              .clamp(0.0, position.maxScrollExtent);
      if (animate) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final queue = player.queue;
    final index = _playingIndex(queue);
    final theme = widget.theme;
    final control = widget.control;
    _syncScrollToCurrent();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.queue_music_rounded, size: 15, color: control),
            const SizedBox(width: 6),
            Text(
              'QUEUE',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: control.withValues(alpha: 0.9),
              ),
            ),
            const Spacer(),
            PearCountChip('${index + 1} / ${queue.length}', color: control),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          // The rows' hover and press fills paint on the nearest Material, not
          // on the list, so scrolling fast let them show through above the
          // list over the controls. Their own clipped Material keeps them in.
          child: ClipRect(
            child: Material(
              type: MaterialType.transparency,
              child: ListView.builder(
                controller: _scrollController,
                padding: EdgeInsets.zero,
                itemExtent: _rowExtent,
                itemCount: queue.length,
                itemBuilder: (context, i) {
                  final song = queue[i];
                  final isCurrent = i == index;
                  final isPlayed = i < index;
                  return InkWell(
                    mouseCursor: WidgetStateMouseCursor.clickable,
                    borderRadius: BorderRadius.circular(PearGlassTokens.r(10)),
                    hoverColor: Colors.white.withValues(
                      alpha: PearOverlay.hover,
                    ),
                    // Desktop rows: instant press fill, no touch ripple.
                    splashFactory: NoSplash.splashFactory,
                    highlightColor: Colors.white.withValues(alpha: 0.06),
                    onTap: () {
                      TactileFeedback.click();
                      player.playSong(
                        song,
                        queue: queue,
                        sourceId: player.queueSourceId,
                        initialIndex: i,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(PearGlassTokens.r(10)),
                        // Same card language as the lists and the queue sheet:
                        // artwork thumbnail per row, and the playing row carries
                        // the track accent.
                        // A faint fill and the accent bar, as the song lists
                        // draw their playing row.
                        color: isCurrent
                            ? Colors.white.withValues(alpha: 0.05)
                            : null,

                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 20,
                            child: isCurrent
                                ? Icon(
                                    Icons.graphic_eq_rounded,
                                    size: 13,
                                    color: control,
                                  )
                                : Text(
                                    PearConsole.on
                                        ? '${i + 1}'.padLeft(2, '0')
                                        : '${i + 1}',
                                    style: PearConsole.on
                                        ? PearConsole.readout(
                                            size: 11,
                                            color: Colors.white.withValues(
                                              alpha: 0.4,
                                            ),
                                          )
                                        : theme.textTheme.labelSmall?.copyWith(
                                            fontSize: 11,
                                            color: Colors.white.withValues(
                                              alpha: 0.35,
                                            ),
                                          ),
                                  ),
                          ),
                          _QueueThumb(song: song),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 12.5,
                                fontWeight: isCurrent
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                // Played tracks stay listed but recede, so the
                                // queue reads as a fixed list with a moving cursor
                                // instead of shrinking as it plays.
                                color: isCurrent
                                    ? control
                                    : Colors.white.withValues(
                                        alpha: isPlayed ? 0.38 : 0.85,
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            song.durationLabel ?? song.sizeLabel,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 11,
                              color: Colors.white.withValues(alpha: 0.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Small rounded artwork square for a pane queue row. Cached bytes paint
/// immediately; the decode is awaited only for songs whose artwork has not
/// been read yet, and a plain tile covers songs without artwork.
class _QueueThumb extends StatelessWidget {
  final Song song;
  const _QueueThumb({required this.song});

  static const double _size = 26;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(PearGlassTokens.r(8)),
      ),
      child: Icon(
        Icons.music_note_rounded,
        size: 13,
        color: Colors.white.withValues(alpha: 0.35),
      ),
    );

    final art = song.artwork;
    Widget image;
    if (art == null || art.isEmpty) {
      image = placeholder;
    } else if (art.startsWith('http')) {
      image = Image.network(
        ArtworkService.optimizeArtworkUrl(art),
        width: _size,
        height: _size,
        cacheWidth: 96,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => placeholder,
      );
    } else {
      final cached = ArtworkPalette.cachedBytes(song);
      image = FutureBuilder<Uint8List?>(
        // A reused row keeps its old snapshot when only the future changes,
        // so key by song to start fresh from this song's cached bytes.
        key: ValueKey(song.id),
        initialData: cached,
        future: ArtworkPalette.bytesAsync(song),
        builder: (context, snapshot) {
          final bytes = snapshot.data ?? cached;
          if (bytes == null || bytes.isEmpty) return placeholder;
          return Image.memory(
            bytes,
            width: _size,
            height: _size,
            cacheWidth: 96,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
          );
        },
      );
    }

    return ClipRRect(borderRadius: BorderRadius.circular(PearGlassTokens.r(8)), child: image);
  }
}

/// Pins the pane's content to its final width while the card around it
/// animates its width, so expanding or collapsing only moves the clip edge.
/// Anything inside that reacts to constraints (the artwork size, its cached
/// glow texture, the queue rows) then keeps one layout for the whole
/// transition instead of re-flowing on every animation frame.
class _PaneLayoutWidth extends StatelessWidget {
  final double width;
  final Widget child;

  const _PaneLayoutWidth({required this.width, required this.child});

  @override
  Widget build(BuildContext context) {
    return OverflowBox(
      minWidth: width,
      maxWidth: width,
      alignment: Alignment.center,
      child: child,
    );
  }
}
