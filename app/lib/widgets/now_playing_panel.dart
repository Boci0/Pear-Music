import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/artwork_service.dart';
import '../services/player_service.dart';
import '../theme/tokens.dart';
import 'player/playback_speed_dialog.dart';
import 'player/player_artwork.dart';
import 'player/player_console_dialog.dart';
import 'player/player_controls.dart';
import 'player/sleep_timer_dialog.dart';
import 'player/stream_quality_info_dialog.dart';
import 'tactile_button.dart';

/// Old-school desktop "Now Playing" pane: big artwork, title, transport
/// controls and a progress line, pinned to the right of the wide shell. The
/// pane also IS the expanded player on wide windows: tapping it grows it in
/// place into the full player stack (artwork hero with the visualizer and
/// lyrics pills, song info, transport, waveform seek bar, volume and Up Next)
/// instead of pushing a separate full-screen route.
class NowPlayingPanel extends StatelessWidget {
  final bool expanded;

  /// Called when the compact pane is tapped or the expanded player's collapse
  /// button is pressed. When null the pane falls back to pushing the
  /// full-screen player route.
  final VoidCallback? onToggleExpanded;

  const NowPlayingPanel({
    super.key,
    this.expanded = false,
    this.onToggleExpanded,
  });

  /// Shared by the shell's width animation and the content cross-fade, so the
  /// pane grows and swaps its content as one motion instead of two.
  static const Duration expandTransitionDuration = Duration(milliseconds: 220);

  /// The pane card's docked widths. The shell animates between them, and the
  /// pane lays its content out at the final width for the whole animation, so
  /// expanding only moves the card's clip edge (see [_PaneLayoutWidth]).
  static const double compactPaneWidth = 348;
  static const double expandedPaneWidth = 508;

  /// The card's border (one per side); the content area is inset by it.
  static const double _kPaneBorder = 1;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final song = player.currentSong;
    final theme = Theme.of(context);
    final accent = song == null || song.artwork == null || song.artwork!.isEmpty
        ? theme.colorScheme.primary
        : ArtworkPalette.dominantSync(song);

    // The artwork wash fades in and out with the expand motion instead of
    // popping on the first frame of the width animation.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: expanded ? 1 : 0),
      duration: expandTransitionDuration,
      curve: Curves.easeOutCubic,
      builder: (context, wash, child) => Container(
        key: const ValueKey('now_playing_panel'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFF151518),
          // Expanded mode carries a soft wash of the song's artwork colour
          // from the top edge, the same gesture the full-screen player makes,
          // so the pane reads as "the player" rather than a plain sidebar
          // card.
          gradient: song != null && wash > 0.001
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                  colors: [
                    accent.withValues(alpha: 0.12 * wash),
                    Colors.transparent,
                  ],
                )
              : null,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: child,
      ),
      child: song == null
          ? _buildEmptyState(theme)
          : AnimatedSwitcher(
              duration: expandTransitionDuration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              // Both states fill the pane, so give them tight constraints
              // while they overlap: the default loose stack would break the
              // Expanded-based expanded layout mid-transition.
              layoutBuilder: (currentChild, previousChildren) => Stack(
                fit: StackFit.expand,
                children: [...previousChildren, ?currentChild],
              ),
              child: KeyedSubtree(
                key: ValueKey(
                  expanded ? 'pane_content_expanded' : 'pane_content_compact',
                ),
                // Lay the content out at the state's final width for the
                // whole transition; the card's clip edge does the revealing.
                // Without this the artwork size, its cached glow texture and
                // the queue rows re-flow on every animation frame, which is
                // what made the expand feel rough.
                child: _PaneLayoutWidth(
                  width: expanded
                      ? expandedPaneWidth - 2 * _kPaneBorder
                      : compactPaneWidth - 2 * _kPaneBorder,
                  child: expanded
                      ? _buildExpandedState(context, player, song, theme)
                      : _buildPlayingState(context, player, song, theme),
                ),
              ),
            ),
    );
  }

  void _collapsePlayer(BuildContext context) {
    // Mirror what leaving the full-screen player used to do: park the
    // window-level effects so the visualizer and lyrics do not keep running
    // once the pane is compact again.
    context.read<AppController?>()?.updateSynthesizerBar(false);
    PlayerArtwork.closeLyrics();
    onToggleExpanded?.call();
  }

  /// The expanded player: the same vertical stack as the compact pane, but
  /// with the complete control set at a larger size.
  Widget _buildExpandedState(
    BuildContext context,
    PlayerService player,
    Song song,
    ThemeData theme,
  ) {
    final controller = context.read<AppController>();
    final accent = ArtworkPalette.dominantSync(song);
    final control = ArtworkPalette.controlAccent(accent);

    return Column(
      key: const ValueKey('now_playing_panel_expanded'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 8, 0),
          child: Row(
            children: [
              TactileIconButton(
                key: const ValueKey('pane_collapse'),
                iconSize: 18,
                icon: const Icon(Icons.close_fullscreen_rounded),
                tooltip: 'Collapse player',
                onPressed: () => _collapsePlayer(context),
              ),
              const Spacer(),
              TactileIconButton(
                iconSize: 18,
                icon: const Icon(Icons.terminal_rounded),
                tooltip: 'Diagnostics Console',
                onPressed: () => PlayerConsoleDialog.show(context),
              ),
              PlaybackSpeedButton(player: player),
              SleepTimerButton(player: player),
              StreamQualityInfoButton(player: player),
              const SizedBox(width: 4),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final artSize = math
                  .min(
                    constraints.maxWidth - 44,
                    math.min(
                      constraints.maxHeight * 0.54,
                      // Keep the info + transport + seek block (with its time
                      // labels) above the fold on shorter windows: only the
                      // artwork flexes, so no control silently drops below the
                      // scroll edge.
                      constraints.maxHeight - 320,
                    ),
                  )
                  .clamp(140.0, 520.0);
              return SingleChildScrollView(
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    PlayerArtworkHero(
                      song: song,
                      size: artSize,
                      artwork: ArtworkPalette.cachedBytes(song),
                      accent: accent,
                    ),
                    const SizedBox(height: 14),
                    PlayerSongInfo(song: song),
                    const SizedBox(height: 4),
                    PlayerTransport(
                      player: player,
                      controller: controller,
                      accent: accent,
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: PlayerSeekBar(
                        player: player,
                        duration: player.duration ?? Duration.zero,
                        accent: accent,
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                ),
              );
            },
          ),
        ),
        // Volume lives outside the scroll area: at shorter window heights it
        // used to end up below the fold with no scrollbar cue, which read as
        // a missing control.
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
          child: PlayerVolumeRow(accent: control),
        ),
        if (player.queue.isNotEmpty)
          SizedBox(
            // The queue yields space before the controls do: on shorter
            // windows it shrinks so the seek bar and its time labels stay
            // above the scroll edge.
            height: math.min(
              216.0,
              math.max(120.0, MediaQuery.sizeOf(context).height * 0.18),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _QueueContextList(
                player: player,
                // One accent with the rest of the app: the same green the
                // library's playing row uses, so the playing row tints
                // identically in every list.
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
              color: Colors.white.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 12),
            Text(
              'Nothing playing',
              style: theme.textTheme.titleSmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Pick a song to start listening',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayingState(
    BuildContext context,
    PlayerService player,
    Song song,
    ThemeData theme,
  ) {
    final controller = context.read<AppController>();
    final accent = ArtworkPalette.dominantSync(song);
    final control = ArtworkPalette.controlAccent(accent);
    final meta = song.sourceDeviceId == 'stream'
        ? 'Stream · Pear Radio'
        : song.sourceDeviceId != null
        ? 'Shared · ${song.sizeLabel}'
        : 'Local · ${song.sizeLabel}';

    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final artSize = math
                    .min(constraints.maxWidth, constraints.maxHeight - 380)
                    .clamp(120.0, constraints.maxWidth);
                return Column(
                  children: [
                    const Spacer(flex: 3),
                    SizedBox(
                      width: artSize,
                      height: artSize,
                      child: _Artwork(song: song),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      song.title,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12.5,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TactileIconButton(
                          icon: Icon(Icons.skip_previous, color: control),
                          iconSize: 28,
                          tooltip: 'Previous',
                          onPressed: () => controller.previousTrack(),
                        ),
                        const SizedBox(width: 4),
                        TactileBounce(
                          onTap: () => controller.togglePlayback(),
                          scaleDown: 0.88,
                          tooltip: player.playbackError != null
                              ? 'Retry'
                              : (player.playing ? 'Pause' : 'Play'),
                          child: SizedBox(
                            width: 52,
                            height: 52,
                            child: Center(
                              child: player.isBuffering
                                  ? SizedBox(
                                      width: 34,
                                      height: 34,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        color: control,
                                      ),
                                    )
                                  : Icon(
                                      player.playing
                                          ? Icons.pause_circle_filled
                                          : Icons.play_circle_filled,
                                      size: 52,
                                      color: control,
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        TactileIconButton(
                          icon: Icon(Icons.skip_next, color: control),
                          iconSize: 28,
                          tooltip: 'Next',
                          onPressed: () => controller.nextTrack(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _ProgressLine(player: player, color: control, theme: theme),
                    const SizedBox(height: 4),
                    PlayerVolumeRow(accent: control),
                    const SizedBox(height: 16),
                    if (player.queue.isNotEmpty)
                      Flexible(
                        flex: 4,
                        child: _QueueContextList(
                          player: player,
                          control: Theme.of(context).colorScheme.primary,
                          theme: theme,
                        ),
                      )
                    else
                      const Spacer(flex: 4),
                  ],
                );
              },
            ),
          ),
        ),
        if (onToggleExpanded != null)
          Positioned(
            top: 10,
            right: 10,
            child: TactileIconButton(
              key: const ValueKey('pane_expand'),
              iconSize: 18,
              icon: const Icon(Icons.open_in_full_rounded),
              tooltip: 'Expand player',
              onPressed: () {
                TactileFeedback.click();
                onToggleExpanded!();
              },
            ),
          ),
      ],
    );
  }
}

class _ProgressLine extends StatelessWidget {
  final PlayerService player;
  final Color color;
  final ThemeData theme;

  const _ProgressLine({
    required this.player,
    required this.color,
    required this.theme,
  });

  String _formatTime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
    return '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final timeStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 10.5,
      color: Colors.white.withValues(alpha: 0.5),
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      initialData: player.duration,
      builder: (context, durSnapshot) {
        final total = durSnapshot.data ?? player.duration ?? Duration.zero;
        final totalMs = total.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          initialData: player.position ?? Duration.zero,
          builder: (context, posSnapshot) {
            final pos = posSnapshot.data ?? player.position ?? Duration.zero;
            final fraction = totalMs <= 0
                ? 0.0
                : (pos.inMilliseconds / totalMs).clamp(0.0, 1.0);
            return Row(
              children: [
                Text(_formatTime(pos), style: timeStyle),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      height: 4,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ColoredBox(
                            color: Colors.white.withValues(alpha: 0.08),
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
  const _Artwork({required this.song});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
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

    return ClipRRect(borderRadius: BorderRadius.circular(16), child: image);
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

  /// Keeps the playing track in view as the queue advances: jump on the first
  /// build, animate on track changes, and only when the track actually changes
  /// (the player notifies on every position tick).
  void _syncScrollToCurrent() {
    final index = widget.player.queueIndex;
    final songId = widget.player.currentSong?.id;
    if (index == _lastIndex && songId == _lastSongId) return;
    final animate = _lastIndex != null;
    _lastIndex = index;
    _lastSongId = songId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final target =
          (index * _rowExtent -
                  position.viewportDimension / 2 +
                  _rowExtent / 2)
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
    final index = player.queueIndex;
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: control.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${index + 1} / ${queue.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  color: control,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
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
                borderRadius: BorderRadius.circular(10),
                hoverColor: Colors.white.withValues(alpha: PearOverlay.hover),
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
                    borderRadius: BorderRadius.circular(10),
                    // Same card language as the lists and the queue sheet:
                    // artwork thumbnail per row, and the playing row carries
                    // the track accent.
                    color: isCurrent
                        ? control.withValues(alpha: 0.14)
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
                                '${i + 1}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 11,
                                  color: Colors.white.withValues(alpha: 0.35),
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
                        song.sizeLabel,
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
        borderRadius: BorderRadius.circular(8),
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

    return ClipRRect(borderRadius: BorderRadius.circular(8), child: image);
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
