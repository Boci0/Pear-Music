import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/player_service.dart';

/// Full-screen player with seek bar, transport controls and volume.
///
/// Responsive across three widths:
///   - **Wide (desktop, >= 900px)**: three panes — playlists on the left, the
///     portrait-style player centred, and the song list (all songs, or the
///     active playlist's songs) on the right. This fills the empty space of a
///     maximised window instead of stretching a two-column layout.
///   - **Mobile portrait**: everything stacked vertically.
///   - **Mobile landscape**: two-column split (artwork/info + controls).
///
/// On mobile a hamburger menu in the top-right opens a drawer that browses
/// Playlists and Songs from the player.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  /// When set, the wide layout's right pane (and the mobile drawer) show this
  /// playlist's songs instead of all songs.
  String? _activePlaylistId;

  /// Opens the library drawer from the app-bar menu. A key is required because
  /// `Scaffold.of(context)` from inside this Scaffold would resolve to the
  /// HomeShell's Scaffold (which has no drawer) and silently do nothing.
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    final player = context.read<PlayerService>();
    if (player.queueSourceId != null && player.queueSourceId!.startsWith('playlist:')) {
      _activePlaylistId = player.queueSourceId!.substring('playlist:'.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final controller = context.read<AppController>();
    final song = player.currentSong;
    final isWide = MediaQuery.sizeOf(context).width >= 900;

    final appBar = AppBar(
      title: isWide ? const Text('Now Playing') : null,
      // The player is pushed over the shell, so always offer a way back. An
      // explicit leading also stops the drawer from swallowing the back button.
      leading: const BackButton(),
      actions: [
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

    final duration = player.duration ?? Duration.zero;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    // Theme the player around the song's artwork: extract a dominant colour
    // (async, cached per song) and smoothly animate the accent when the track
    // changes. The colour drives the background wash, artwork glow, play
    // button and sliders via a Theme override, so every `scheme.primary` use
    // in the player follows the album art.
    return Scaffold(
      key: _scaffoldKey,
      appBar: appBar,
      drawer: isWide
          ? null
          : _PlayerDrawer(
              controller: controller,
              player: player,
              currentSong: song,
              activePlaylistId: _activePlaylistId,
              onActivePlaylistChanged: (id) =>
                  setState(() => _activePlaylistId = id),
            ),
      // The app-wide theme already follows the song's artwork colour, so the
      // player only adds a soft background wash that fades when the track
      // changes.
      body: TweenAnimationBuilder<Color?>(
        tween: ColorTween(
          begin: ArtworkPalette.fallback,
          end: ArtworkPalette.dominantSync(song),
        ),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        builder: (context, animColor, _) {
          final activeAccent = animColor ?? ArtworkPalette.fallback;
          return SafeArea(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: isWide
                  ? _WideBody(
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
                      ? _LandscapeBody(
                          controller: controller,
                          player: player,
                          song: song,
                          duration: duration,
                          accent: activeAccent,
                        )
                      : _PortraitBody(
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



/// Portrait layout: artwork on top, controls below.
class _PortraitBody extends StatelessWidget {
  final AppController controller;
  final PlayerService player;
  final Song song;
  final Duration duration;
  final Color accent;
  const _PortraitBody({
    required this.controller,
    required this.player,
    required this.song,
    required this.duration,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Spacer(),
        _Artwork(size: 240, artwork: ArtworkPalette.bytes(song), accent: accent),
        const SizedBox(height: 32),
        _SongInfo(song: song),
        const Spacer(),
        // Seek bar + time labels. Only this subtree subscribes to the
        // position stream, so a 250 ms position tick does NOT rebuild the
        // whole screen (artwork gradient, controls, volume slider, etc).
        _SeekBar(player: player, duration: duration),
        const SizedBox(height: 8),
        _Transport(player: player, controller: controller),
        const Spacer(),
        const _VolumeRow(),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Landscape / wide layout: artwork + song info on the left, controls on the
/// right. The whole thing is capped at a comfortable max width and centred, so
/// on a maximised desktop window it reads as a proper music player instead of
/// two columns stretched edge-to-edge.
class _LandscapeBody extends StatelessWidget {
  final AppController controller;
  final PlayerService player;
  final Song song;
  final Duration duration;
  final Color accent;
  const _LandscapeBody({
    required this.controller,
    required this.player,
    required this.song,
    required this.duration,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      // Artwork scales with the available height (bigger on a desktop window,
      // smaller on a phone in landscape) but is capped so the column fits.
      final artSize = (constraints.maxHeight * 0.6).clamp(120.0, 340.0);
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Left: artwork + song info (centred; scrolls if ever too tall).
              Expanded(
                flex: 5,
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Artwork(
                            size: artSize,
                            artwork: ArtworkPalette.bytes(song),
                            accent: accent),
                        const SizedBox(height: 20),
                        _SongInfo(song: song),
                      ],
                    ),
                  ),
                ),
              ),
              // Right: seek bar, transport, volume (vertically centred, capped
              // width so sliders don't stretch across a huge window).
              Expanded(
                flex: 4,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: _SeekBar(player: player, duration: duration),
                    ),
                    const SizedBox(height: 12),
                    _Transport(player: player, controller: controller),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: const _VolumeRow(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// Song title + source line.
class _SongInfo extends StatelessWidget {
  final Song song;
  const _SongInfo({required this.song});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final isFav = controller.isFavorite(song.id);
    final theme = Theme.of(context);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 48),
            Expanded(
              child: Text(
                song.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall,
              ),
            ),
            IconButton(
              icon: Icon(
                isFav ? Icons.favorite : Icons.favorite_border,
                color: isFav ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
              ),
              tooltip: isFav ? 'Remove from favorites' : 'Add to favorites',
              onPressed: () => controller.toggleFavorite(song.id),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          song.sourceDeviceId == null ? 'Added on this device' : 'Shared',
          style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

/// Previous / play-pause / next transport buttons, flanked by shuffle and
/// repeat controls.
class _Transport extends StatelessWidget {
  final PlayerService player;
  final AppController controller;
  const _Transport({required this.player, required this.controller});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loopIcon = switch (player.loopMode) {
      LoopSetting.one => Icons.repeat_one,
      _ => Icons.repeat,
    };
    final loopActive = player.loopMode != LoopSetting.off;
    // The three loop states are shown explicitly so the user always knows
    // which one is active: no loop / whole album / this one song.
    final loopLabel = switch (player.loopMode) {
      LoopSetting.one => 'Repeat one (this song)',
      LoopSetting.all => 'Repeat all (album)',
      LoopSetting.off => 'No repeat',
    };
    // Show both repeat AND shuffle state so it is obvious when each is on.
    final stateLabel = [
      if (player.shuffle) 'Shuffle on',
      loopLabel,
    ].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              iconSize: 32,
              icon: Icon(
                Icons.shuffle,
                color: player.shuffle
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
              tooltip: player.shuffle ? 'Shuffle on' : 'Shuffle',
              onPressed: controller.toggleShuffle,
            ),
            IconButton(
              iconSize: 44,
              icon: const Icon(Icons.skip_previous_rounded),
              onPressed: () => controller.previousTrack(),
            ),
            IconButton(
              iconSize: 72,
              icon: Icon(
                player.playing
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled,
                color: scheme.primary,
              ),
              onPressed: () => controller.togglePlayback(),
            ),
            IconButton(
              iconSize: 44,
              icon: const Icon(Icons.skip_next_rounded),
              onPressed: () => controller.nextTrack(),
            ),
            IconButton(
              iconSize: 32,
              icon: Icon(
                loopIcon,
                color: loopActive ? scheme.primary : scheme.onSurfaceVariant,
              ),
              tooltip: loopLabel,
              onPressed: controller.toggleLoop,
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          stateLabel,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: loopActive || player.shuffle
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

/// Volume icons + slider.
class _VolumeRow extends StatelessWidget {
  const _VolumeRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.volume_down,
            color: Theme.of(context).colorScheme.onSurfaceVariant),
        const Expanded(child: _VolumeSlider()),
        Icon(Icons.volume_up,
            color: Theme.of(context).colorScheme.onSurfaceVariant),
      ],
    );
  }
}

/// Seek bar + current/total time. Subscribes to the throttled position stream
/// (250 ms) so a position tick only rebuilds this small subtree instead of the
/// whole player screen.
///
/// While the user drags, a local value takes over so the 250 ms stream ticks
/// no longer yank the thumb back — that fighting was what made the slider feel
/// very laggy. The seek only commits once the finger lifts.
class _SeekBar extends StatefulWidget {
  final PlayerService player;
  final Duration duration;
  const _SeekBar({required this.player, required this.duration});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  /// Non-null while the user is dragging: the thumb position in ms.
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      initialData: widget.player.position,
      builder: (context, snapshot) {
        final totalMs = widget.duration.inMilliseconds;
        final streamMs =
            (snapshot.data ?? Duration.zero).inMilliseconds.clamp(0, totalMs);
        final posMs = _dragMs ?? streamMs.toDouble();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Slider(
              value: totalMs == 0 ? 0 : posMs.clamp(0, totalMs.toDouble()),
              max: totalMs == 0 ? 1 : totalMs.toDouble(),
              onChangeStart: (_) => setState(() => _dragMs = posMs),
              onChanged: (v) => setState(() => _dragMs = v),
              onChangeEnd: (v) {
                setState(() => _dragMs = null);
                widget.player.seek(Duration(milliseconds: v.round()));
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(Duration(milliseconds: posMs.round())),
                      style: Theme.of(context).textTheme.labelSmall),
                  Text(_fmt(widget.duration),
                      style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Volume slider that applies the volume in real time as you drag.
///
/// It watches PlayerService directly and calls [PlayerService.setVolume] on
/// every onChanged tick (real-time audio). setVolume does not notifyListeners,
/// so while dragging we keep a local [_dragValue] that owns the thumb —
/// otherwise the thumb would never move because nothing rebuilds it.
class _VolumeSlider extends StatefulWidget {
  const _VolumeSlider();

  @override
  State<_VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<_VolumeSlider> {
  /// Non-null while the user is dragging: the thumb position.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final value = _dragValue ?? player.volume.clamp(0.0, 1.0);
    return Slider(
      value: value,
      onChangeStart: (_) =>
          setState(() => _dragValue = player.volume.clamp(0.0, 1.0)),
      onChanged: (v) {
        setState(() => _dragValue = v);
        player.setVolume(v);
      },
      onChangeEnd: (_) => setState(() => _dragValue = null),
    );
  }
}

class _Artwork extends StatelessWidget {
  final Uint8List? artwork;
  final double size;
  final Color? accent;
  const _Artwork({this.artwork, this.size = 240, this.accent});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(16);
    final glowColor = accent ?? scheme.primary;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            glowColor,
            scheme.tertiary.withValues(alpha: 0.7),
          ],
        ),
      ),
      child: Icon(Icons.music_note, size: size * 0.4, color: scheme.onPrimary),
    );
    final art = artwork;
    if (art == null || art.isEmpty) return placeholder;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Image.memory(
          art,
          width: size,
          height: size,
          cacheWidth: (size * 2).round(),
          cacheHeight: (size * 2).round(),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => placeholder,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Wide (desktop) layout: playlists | player | songs
// ---------------------------------------------------------------------------

class _WideBody extends StatefulWidget {
  final AppController controller;
  final PlayerService player;
  final Song song;
  final Duration duration;
  final Color accent;
  final String? activePlaylistId;
  final ValueChanged<String?> onActivePlaylistChanged;
  const _WideBody({
    required this.controller,
    required this.player,
    required this.song,
    required this.duration,
    required this.accent,
    required this.activePlaylistId,
    required this.onActivePlaylistChanged,
  });

  @override
  State<_WideBody> createState() => _WideBodyState();
}

class _WideBodyState extends State<_WideBody> {
  int _selectedTab = 0; // 0 = Queue, 1 = Playlists

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = widget.controller;
    final player = widget.player;
    final song = widget.song;
    final duration = widget.duration;
    final accent = widget.accent;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1300),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left Hero Section (Artwork, Title, Artist, Badges)
            Expanded(
              flex: 5,
              child: Card(
                elevation: 0,
                color: scheme.surfaceContainerLow.withValues(alpha: 0.6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.2),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final artSize =
                                (constraints.maxHeight * 0.85).clamp(180.0, 380.0);
                            return Center(
                              child: _Artwork(
                                size: artSize,
                                artwork: ArtworkPalette.bytes(song),
                                accent: accent,
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 24),
                      _SongInfo(song: song),
                      if (player.queueTitle != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Text(
                            'Playing from ${player.queueTitle}',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 20),
            // Right Section (Interactive Queue / Playlists & Docked Controls)
            Expanded(
              flex: 6,
              child: Card(
                elevation: 0,
                color: scheme.surfaceContainerLow.withValues(alpha: 0.6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.2),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header Navigation
                      Row(
                        children: [
                          SegmentedButton<int>(
                            segments: [
                              ButtonSegment(
                                value: 0,
                                icon: const Icon(Icons.queue_music_rounded, size: 18),
                                label: Text('Queue (${player.queue.length})'),
                              ),
                              ButtonSegment(
                                value: 1,
                                icon: const Icon(Icons.playlist_play_rounded, size: 18),
                                label: Text('Playlists (${controller.playlists.length})'),
                              ),
                            ],
                            selected: {_selectedTab},
                            onSelectionChanged: (set) =>
                                setState(() => _selectedTab = set.first),
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                          const Spacer(),
                          if (_selectedTab == 0 && player.queue.length > 1)
                            TextButton.icon(
                              onPressed: () => player.toggleShuffle(),
                              icon: Icon(
                                Icons.shuffle_rounded,
                                size: 16,
                                color: player.shuffle
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                              label: Text(
                                player.shuffle ? 'Shuffled' : 'Shuffle',
                                style: TextStyle(
                                  color: player.shuffle
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      // Tab Body
                      Expanded(
                        child: _selectedTab == 0
                            ? _WideQueueView(
                                player: player,
                                currentSong: song,
                                scheme: scheme,
                              )
                            : _WidePlaylistsView(
                                controller: controller,
                                activePlaylistId: widget.activePlaylistId,
                                onSelect: (pl) {
                                  widget.onActivePlaylistChanged(pl.id);
                                  controller.playPlaylist(pl);
                                },
                                scheme: scheme,
                              ),
                      ),
                      const SizedBox(height: 14),
                      const Divider(height: 1),
                      const SizedBox(height: 14),
                      // Docked Controls
                      _SeekBar(player: player, duration: duration),
                      const SizedBox(height: 10),
                      _Transport(player: player, controller: controller),
                      const SizedBox(height: 10),
                      const _VolumeRow(),
                    ],
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

class _WideQueueView extends StatelessWidget {
  final PlayerService player;
  final Song currentSong;
  final ColorScheme scheme;
  const _WideQueueView({
    required this.player,
    required this.currentSong,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final queue = player.queue;
    if (queue.isEmpty) {
      return const Center(child: Text('Queue is empty'));
    }

    return ListView.builder(
      itemCount: queue.length,
      itemBuilder: (context, i) {
        final item = queue[i];
        final isCurrent = item.id == currentSong.id;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: isCurrent
                ? scheme.primaryContainer.withValues(alpha: 0.4)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            dense: true,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            leading: isCurrent
                ? Icon(Icons.graphic_eq_rounded, color: scheme.primary, size: 20)
                : Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
            title: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: isCurrent
                  ? TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.bold,
                    )
                  : null,
            ),
            subtitle: Text(
              item.sourceDeviceId == null ? 'Local track' : 'Shared',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isCurrent
                        ? scheme.primary.withValues(alpha: 0.8)
                        : scheme.onSurfaceVariant,
                  ),
            ),
            trailing: isCurrent
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'PLAYING',
                      style: TextStyle(
                        color: scheme.onPrimary,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                : null,
            onTap: () => player.playSong(item, queue: queue),
          ),
        );
      },
    );
  }
}

class _WidePlaylistsView extends StatelessWidget {
  final AppController controller;
  final String? activePlaylistId;
  final ValueChanged<Playlist> onSelect;
  final ColorScheme scheme;
  const _WidePlaylistsView({
    required this.controller,
    required this.activePlaylistId,
    required this.onSelect,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final playlists = controller.playlists;
    if (playlists.isEmpty) {
      return const Center(child: Text('No playlists yet'));
    }

    return ListView.builder(
      itemCount: playlists.length,
      itemBuilder: (context, i) {
        final pl = playlists[i];
        final selected = pl.id == activePlaylistId;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer.withValues(alpha: 0.4)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            dense: true,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            leading: Icon(
              Icons.playlist_play_rounded,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            title: Text(
              pl.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: selected
                  ? TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.bold,
                    )
                  : null,
            ),
            subtitle: Text('${pl.songIds.length} songs'),
            trailing: IconButton(
              icon: const Icon(Icons.play_circle_filled_rounded),
              color: scheme.primary,
              tooltip: 'Play playlist',
              onPressed: () => onSelect(pl),
            ),
            onTap: () => onSelect(pl),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile drawer: browse Playlists + Songs from the player
// ---------------------------------------------------------------------------

class _PlayerDrawer extends StatelessWidget {
  final AppController controller;
  final PlayerService player;
  final Song currentSong;
  final String? activePlaylistId;
  final ValueChanged<String?> onActivePlaylistChanged;
  const _PlayerDrawer({
    required this.controller,
    required this.player,
    required this.currentSong,
    required this.activePlaylistId,
    required this.onActivePlaylistChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playlists = controller.playlists;
    final playlist = _playlistById(controller, activePlaylistId);
    final String sectionTitle;
    final List<Song> songs;
    if (playlist != null) {
      sectionTitle = playlist.name;
      songs = _songsForPlaylist(controller, playlist);
    } else if (player.queueSourceId == 'favorites') {
      sectionTitle = 'Favorites';
      songs = controller.getSortedSongs(
          controller.songs.where((s) => controller.isFavorite(s.id)).toList());
    } else {
      sectionTitle = 'All Songs';
      songs = controller.getSortedSongs(controller.songs);
    }

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Library',
                        style: Theme.of(context).textTheme.titleLarge),
                  ),
                  if (playlist != null)
                    ActionChip(
                      label: const Text('All Songs'),
                      onPressed: () {
                        onActivePlaylistChanged(null);
                        Navigator.of(context).pop();
                      },
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  _DrawerHeader(icon: Icons.queue_music, label: 'Playlists'),
                  if (playlists.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Text('No playlists yet'),
                    )
                  else
                    for (final pl in playlists)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.playlist_play,
                          color: pl.id == activePlaylistId
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                        title: Text(pl.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${pl.songIds.length} songs'),
                        selected: pl.id == activePlaylistId,
                        onTap: () {
                          onActivePlaylistChanged(pl.id);
                          Navigator.of(context).pop();
                          controller.playPlaylist(pl);
                        },
                      ),
                  const Divider(),
                  _DrawerHeader(
                    icon: Icons.music_note,
                    label: sectionTitle,
                  ),
                  if (songs.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Text('No songs'),
                    )
                  else
                    for (final s in songs)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          s.id == currentSong.id
                              ? Icons.graphic_eq
                              : Icons.music_note,
                          color: s.id == currentSong.id
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                        title: Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: s.id == currentSong.id
                              ? TextStyle(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.w600,
                                )
                              : null,
                        ),
                        onTap: () {
                          Navigator.of(context).pop();
                          player.playSong(
                            s,
                            queue: songs,
                            sourceId: playlist != null
                                ? 'playlist:${playlist.id}'
                                : (player.queueSourceId == 'favorites'
                                    ? 'favorites'
                                    : 'library'),
                            sourceTitle: sectionTitle,
                          );
                        },
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  const _DrawerHeader({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(label, style: Theme.of(context).textTheme.labelLarge),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared lookup helpers
// ---------------------------------------------------------------------------

Playlist? _playlistById(AppController controller, String? id) {
  if (id == null) return null;
  for (final pl in controller.playlists) {
    if (pl.id == id) return pl;
  }
  return null;
}

List<Song> _songsForPlaylist(AppController controller, Playlist playlist) => [
      for (final id in playlist.songIds)
        if (controller.library.findById(id) != null)
          controller.library.findById(id)!,
    ];
