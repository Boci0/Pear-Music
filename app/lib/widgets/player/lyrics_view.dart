import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/lyrics_display.dart';
import '../../services/lyrics_service.dart';
import '../../services/player_service.dart';
import 'lyric_sync_sheet.dart';

/// Interactive synchronized lyric display.
///
/// Highlights the currently playing lyric line with a glowing sentence effect,
/// automatically keeps the active line centered in the middle of the card,
/// and allows tapping any line to seek playback directly.
class LyricsView extends StatefulWidget {
  final Song song;
  final PlayerService player;
  final Color? accent;
  final double size;
  final bool isVisible;

  const LyricsView({
    super.key,
    required this.song,
    required this.player,
    this.accent,
    required this.size,
    this.isVisible = true,
  });

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> with WidgetsBindingObserver {
  List<LyricLine> _lyrics = const [];
  bool _isLoading = true;
  int _activeIndex = -1;
  StreamSubscription<Duration>? _positionSub;
  bool _isForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.player.scrubbingPositionNotifier.addListener(_onScrubbingChanged);
    ArtworkPalette.paletteNotifier.addListener(_onPaletteUpdated);
    LyricsDisplay.mode.addListener(_onPaletteUpdated);
    _loadLyrics();
  }

  void _onPaletteUpdated() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isForeground = state == AppLifecycleState.resumed;
    if (_isForeground != isForeground) {
      _isForeground = isForeground;
      _updateSubscriptionState();
      if (_isForeground && widget.isVisible) {
        _snapToCurrentPosition();
      }
    }
  }

  @override
  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.scrubbingPositionNotifier.removeListener(_onScrubbingChanged);
      widget.player.scrubbingPositionNotifier.addListener(_onScrubbingChanged);
    }
    if (oldWidget.song.id != widget.song.id) {
      _loadLyrics();
    } else if (widget.isVisible != oldWidget.isVisible) {
      _updateSubscriptionState();
      if (widget.isVisible && _isForeground) {
        _snapToCurrentPosition();
      }
    }
  }

  void _updateSubscriptionState() {
    final sub = _positionSub;
    if (sub == null) return;
    final shouldListen = _isForeground && widget.isVisible;
    if (shouldListen) {
      if (sub.isPaused) {
        sub.resume();
      }
    } else {
      if (!sub.isPaused) {
        sub.pause();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.player.scrubbingPositionNotifier.removeListener(_onScrubbingChanged);
    ArtworkPalette.paletteNotifier.removeListener(_onPaletteUpdated);
    LyricsDisplay.mode.removeListener(_onPaletteUpdated);
    _positionSub?.cancel();
    super.dispose();
  }

  Future<void> _loadLyrics() async {
    setState(() {
      _isLoading = true;
      _lyrics = const [];
      _activeIndex = -1;
    });
    _positionSub?.cancel();

    // Check if song has local file path
    String? localAudioPath;
    final library = widget.player.library;
    if (library.hasSongFile(widget.song)) {
      localAudioPath = library.songFile(widget.song).path;
    }

    final songId = widget.song.id;
    final lyrics = await LyricsService.getLyrics(
      widget.song,
      localAudioPath: localAudioPath,
      duration: widget.player.duration,
    );

    if (!mounted || widget.song.id != songId) return;

    setState(() {
      _lyrics = lyrics;
      _isLoading = false;
    });

    if (lyrics.isNotEmpty) {
      _positionSub = widget.player.positionStream.listen(_onPositionUpdate);
      _updateSubscriptionState();
      if (_isForeground && widget.isVisible) {
        _snapToCurrentPosition();
      }
    }
  }

  void _snapToCurrentPosition() {
    if (_lyrics.isEmpty) return;
    final currentPos = widget.player.position ?? Duration.zero;
    final index = LyricsService.findActiveIndex(_lyrics, currentPos);
    if (index >= 0 && mounted) {
      setState(() {
        _activeIndex = index;
      });
    }
  }

  void _onScrubbingChanged() {
    final scrubPos = widget.player.scrubbingPosition;
    if (scrubPos != null) {
      _onPositionUpdate(scrubPos, isScrubbing: true);
    } else {
      final currentPos = widget.player.position ?? Duration.zero;
      _onPositionUpdate(currentPos, isScrubbing: false);
    }
  }

  void _onPositionUpdate(Duration position, {bool isScrubbing = false}) {
    if (_lyrics.isEmpty || !mounted || !widget.isVisible || !_isForeground) return;

    // Suppress background audio playback ticks while user is actively dragging the slider
    if (!isScrubbing && widget.player.scrubbingPosition != null) return;

    final newIndex = LyricsService.findActiveIndex(_lyrics, position);
    if (newIndex != _activeIndex) {
      setState(() {
        _activeIndex = newIndex;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final glowColor = widget.accent ?? scheme.primary;
    // Dark text wins earlier for lyrics readability: saturated bright covers
    // (red, pink, orange) read poorly with white text even though the
    // decorative tinting heuristic calls them dark. The heuristic is only a
    // guess, so the Lyrics Options sheet lets the user force the text colour.
    final isLight = LyricsDisplay.resolveDarkText(
      mode: LyricsDisplay.mode.value,
      artworkPrefersDarkText: ArtworkPalette.prefersDarkText(widget.song),
    );

    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: glowColor,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Finding lyrics...',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: isLight
                    ? const Color(0xFF141416).withValues(alpha: 0.75)
                    : Colors.white.withValues(alpha: 0.70),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    if (_lyrics.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lyrics_outlined,
                size: 38,
                color: isLight
                    ? const Color(0xFF141416).withValues(alpha: 0.50)
                    : Colors.white.withValues(alpha: 0.50),
              ),
              const SizedBox(height: 10),
              Text(
                'No lyrics available',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: isLight
                      ? const Color(0xFF141416).withValues(alpha: 0.88)
                      : Colors.white.withValues(alpha: 0.85),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.song.title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isLight
                      ? const Color(0xFF141416).withValues(alpha: 0.55)
                      : Colors.white.withValues(alpha: 0.50),
                  fontSize: 12,
                ),
              ),
              Wrap(
                spacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: _loadLyrics,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Retry'),
                    style: TextButton.styleFrom(
                      foregroundColor: isLight ? const Color(0xFF141416) : glowColor,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      showLyricSyncSheet(
                        context,
                        song: widget.song,
                        player: widget.player,
                        initialSearchOpen: true,
                        onLyricsUpdated: _loadLyrics,
                      );
                    },
                    icon: const Icon(Icons.search_rounded, size: 16),
                    label: const Text('Search Lyrics'),
                    style: TextButton.styleFrom(
                      foregroundColor: isLight ? const Color(0xFF141416) : glowColor,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return _buildPopLyricsView(glowColor, isLight: isLight);
  }

  Widget _buildPopLyricsView(Color glowColor, {required bool isLight}) {
    final active = (_activeIndex >= 0 && _activeIndex < _lyrics.length)
        ? _lyrics[_activeIndex]
        : (_lyrics.isNotEmpty ? _lyrics[0] : null);

    final text = (active == null || active.text.isEmpty) ? '···' : active.text;

    final scale = (widget.size / 280.0).clamp(0.85, 1.25);
    final double baseFontSize;
    if (text.length <= 20) {
      baseFontSize = 24.0;
    } else if (text.length <= 45) {
      baseFontSize = 21.0;
    } else if (text.length <= 70) {
      baseFontSize = 19.0;
    } else {
      baseFontSize = 16.5;
    }
    final fontSize = (baseFontSize * scale).roundToDouble();

    final isScrubbing = widget.player.scrubbingPosition != null;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: AnimatedSwitcher(
          duration: isScrubbing ? Duration.zero : const Duration(milliseconds: 140),
          switchInCurve: const Interval(0.35, 1.0, curve: Curves.easeOutQuad),
          switchOutCurve: const Interval(0.65, 1.0, curve: Curves.easeInQuad),
          layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
            return Stack(
              alignment: Alignment.center,
              children: <Widget>[
                ...previousChildren,
                ?currentChild,
              ],
            );
          },
          transitionBuilder: (Widget child, Animation<double> animation) {
            if (isScrubbing) return child;
            return FadeTransition(
              opacity: animation,
              child: child,
            );
          },
          child: Container(
            key: ValueKey('pop_lyric_${widget.song.id}_$_activeIndex'),
            alignment: Alignment.center,
            child: Text(
              text,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                wordSpacing: 1.0,
                height: 1.40,
                color: isLight ? const Color(0xFF141416) : Colors.white,
                // The glow always follows the song accent so the lyric text
                // matches the artwork palette in either text colour.
                shadows: [
                  Shadow(
                    color: glowColor.withValues(alpha: isLight ? 0.55 : 0.85),
                    blurRadius: 8.0,
                  ),
                  Shadow(
                    color: glowColor.withValues(alpha: isLight ? 0.30 : 0.45),
                    blurRadius: 4.0,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

