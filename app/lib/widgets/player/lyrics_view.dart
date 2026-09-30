import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/lyrics_display.dart';
import '../../services/loudness_service.dart';
import '../../services/lyrics_service.dart';
import '../../services/player_service.dart';
import 'lyric_sync_sheet.dart';

/// Synchronized lyric display: the current line, centred in the card, lights
/// up word by word as it is sung (by the lyrics' own word timing when they
/// have it, otherwise an estimate spread across the line).
class LyricsView extends StatefulWidget {
  final Song song;
  final PlayerService player;
  final Color? accent;
  final double size;
  final bool isVisible;

  /// Space kept free at the bottom of the card (the visualizer's bars); the
  /// line is centred in what is left above it.
  final double bottomInset;

  const LyricsView({
    super.key,
    required this.song,
    required this.player,
    this.accent,
    required this.size,
    this.isVisible = true,
    this.bottomInset = 0,
  });

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  List<LyricLine> _lyrics = const [];
  bool _isLoading = true;
  int _activeIndex = -1;
  StreamSubscription<Duration>? _positionSub;

  /// The song position, advanced every frame between the player's position
  /// updates (4 a second) so the glow moves smoothly through the line.
  final ValueNotifier<Duration> _sweepPosition = ValueNotifier(Duration.zero);
  late final Ticker _sweepTicker;
  Duration _anchorPosition = Duration.zero;
  final Stopwatch _sinceAnchor = Stopwatch();
  int _spansIndex = -1;
  List<LyricSpan> _spans = const [];

  /// [_spans] cut into letters, each with the moment it is sung.
  List<({String text, Duration at})> _glyphs = const [];
  bool _isForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sweepTicker = createTicker(_onSweepTick);
    widget.player.scrubbingPositionNotifier.addListener(_onScrubbingChanged);
    ArtworkPalette.paletteNotifier.addListener(_onPaletteUpdated);
    LyricsDisplay.mode.addListener(_onPaletteUpdated);
    LyricsDisplay.wordGlow.addListener(_onPaletteUpdated);
    LyricsDisplay.glowDelayMs.addListener(_onPaletteUpdated);
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
      oldWidget.player.scrubbingPositionNotifier.removeListener(
        _onScrubbingChanged,
      );
      widget.player.scrubbingPositionNotifier.addListener(_onScrubbingChanged);
      _positionSub?.cancel();
      _positionSub = null;
      _updateSubscriptionState();
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

  /// Listens to the position only while lyrics are on screen. The position
  /// stream is shared (broadcast), and a paused broadcast subscription keeps
  /// every event it misses, so hidden lyrics cancel instead of pausing: hours
  /// in the background would otherwise pile up and replay as a burst.
  void _updateSubscriptionState() {
    final shouldListen =
        _lyrics.isNotEmpty && _isForeground && widget.isVisible;
    if (shouldListen && _positionSub == null) {
      _positionSub = widget.player.positionStream.listen(_onPositionUpdate);
    } else if (!shouldListen && _positionSub != null) {
      _positionSub!.cancel();
      _positionSub = null;
    }
    _syncSweepTicker();
  }

  /// The length of [LyricsView.song] once the player has loaded it. Right
  /// after a song change the player still reports the previous song's
  /// length, and lyrics picked by that length get saved for good.
  Future<Duration?> _loadedDuration() async {
    final player = widget.player;
    final songId = widget.song.id;
    bool loaded() =>
        player.currentSong?.id == songId &&
        !player.isAdvancing &&
        !player.isLoadingTrack &&
        player.duration != null;
    if (!loaded() && player.currentSong?.id == songId) {
      final ready = Completer<void>();
      void check() {
        if (loaded() && !ready.isCompleted) ready.complete();
      }

      player.addListener(check);
      try {
        await ready.future.timeout(
          const Duration(seconds: 8),
          onTimeout: () {},
        );
      } finally {
        player.removeListener(check);
      }
    }
    return loaded() ? player.duration : null;
  }

  /// Whether the line on screen is lighting up word by word (set in build).
  bool _sweeping = false;

  /// Runs the per-frame clock only while a line is sweeping on screen: a
  /// running ticker makes the device draw every frame, which is wasted when
  /// the whole line is simply lit.
  void _syncSweepTicker() {
    final run = _sweeping &&
        _positionSub != null &&
        _isForeground &&
        widget.isVisible;
    if (run && !_sweepTicker.isActive) {
      _sweepTicker.start();
    } else if (!run && _sweepTicker.isActive) {
      _sweepTicker.stop();
    }
  }

  /// Takes a fresh position from the player as the point the sweep runs on
  /// from.
  void _anchorAt(Duration position) {
    _anchorPosition = position;
    _sinceAnchor
      ..reset()
      ..start();
    _sweepPosition.value = position;
  }

  void _onSweepTick(Duration _) {
    final scrub = widget.player.scrubbingPosition;
    if (scrub != null) {
      _sweepPosition.value = scrub;
      return;
    }
    if (!widget.player.playing) {
      // Hold still while paused, and restart the clock from here so resuming
      // does not first leap ahead by the time spent paused.
      _anchorPosition = _sweepPosition.value;
      _sinceAnchor.reset();
      return;
    }
    // Never run more than a moment past the last real position, so a stall
    // (buffering) does not let the glow race ahead of the singer.
    final elapsed = _sinceAnchor.elapsed * widget.player.speed;
    _sweepPosition.value =
        _anchorPosition +
        (elapsed > const Duration(milliseconds: 600)
            ? const Duration(milliseconds: 600)
            : elapsed);
  }

  /// [style] with its font made smaller (down to 60%) until [text] fits
  /// [room] when wrapped at its full width.
  TextStyle? _fitToRoom(TextStyle? style, String text, BoxConstraints room) {
    final start = style?.fontSize;
    if (style == null ||
        start == null ||
        !room.hasBoundedWidth ||
        !room.hasBoundedHeight) {
      return style;
    }
    final minSize = start * 0.6;
    var size = start;
    while (true) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style.copyWith(fontSize: size)),
        textAlign: TextAlign.center,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: room.maxWidth);
      final fits = painter.height <= room.maxHeight;
      painter.dispose();
      if (fits || size <= minSize) return style.copyWith(fontSize: size);
      size = (size * 0.92).clamp(minSize, start);
    }
  }

  /// Opacity of words still to be sung: far enough back that the sung part
  /// of the line stands out on any cover.
  static const double _waitingAlpha = 0.30;

  /// How long a letter takes to go from waiting to fully lit.
  static const int _glowRampMicros = 150000;

  /// The colour sung words take in dark-text mode: a very dark shade of the
  /// song accent when it has real colour, otherwise plain [ink]. A pale or
  /// grey accent darkened only a little ends up the same grey as the words
  /// still waiting, and the sweep disappears.
  static Color _deepInk(Color accent, Color ink) {
    final hsl = HSLColor.fromColor(accent);
    if (hsl.saturation < 0.3) return ink;
    return hsl
        .withLightness(0.18)
        .withSaturation(hsl.saturation.clamp(0.0, 0.7))
        .toColor();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.player.scrubbingPositionNotifier.removeListener(_onScrubbingChanged);
    ArtworkPalette.paletteNotifier.removeListener(_onPaletteUpdated);
    LyricsDisplay.mode.removeListener(_onPaletteUpdated);
    LyricsDisplay.wordGlow.removeListener(_onPaletteUpdated);
    LyricsDisplay.glowDelayMs.removeListener(_onPaletteUpdated);
    _positionSub?.cancel();
    _sweepTicker.dispose();
    _sweepPosition.dispose();
    super.dispose();
  }

  Future<void> _loadLyrics() async {
    setState(() {
      _isLoading = true;
      _lyrics = const [];
      _activeIndex = -1;
      _spansIndex = -1;
      _sweeping = false;
    });
    _positionSub?.cancel();
    _positionSub = null;
    _syncSweepTicker();

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
      durationLookup: _loadedDuration,
    );

    if (!mounted || widget.song.id != songId) return;

    setState(() {
      _lyrics = lyrics;
      _isLoading = false;
    });

    if (lyrics.isNotEmpty) {
      _updateSubscriptionState();
      if (_isForeground && widget.isVisible) {
        _snapToCurrentPosition();
      }
      // Lyrics saved before word timing was looked up get one background
      // look, and switch over in place if real timing turns up.
      if (!lyrics.any((l) => l.words.isNotEmpty) &&
          LyricsDisplay.wordGlow.value != WordGlowMode.off) {
        unawaited(_upgradeWordTiming(songId, localAudioPath));
      }
    }
  }

  Future<void> _upgradeWordTiming(String songId, String? localAudioPath) async {
    final upgraded = await LyricsService.upgradeWordTiming(
      widget.song,
      localAudioPath: localAudioPath,
      duration: await _loadedDuration(),
    );
    if (upgraded == null || !mounted || widget.song.id != songId) return;
    setState(() {
      _lyrics = upgraded;
      _spansIndex = -1;
    });
    _snapToCurrentPosition();
  }

  void _snapToCurrentPosition() {
    if (_lyrics.isEmpty) return;
    final currentPos = widget.player.position ?? Duration.zero;
    _anchorAt(currentPos);
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
    if (_lyrics.isEmpty || !mounted || !widget.isVisible || !_isForeground) {
      return;
    }

    // Suppress background audio playback ticks while user is actively dragging the slider
    if (!isScrubbing && widget.player.scrubbingPosition != null) return;

    _anchorAt(position);
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
                      foregroundColor: isLight
                          ? const Color(0xFF141416)
                          : glowColor,
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
                      foregroundColor: isLight
                          ? const Color(0xFF141416)
                          : glowColor,
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
    final textColor = isLight ? const Color(0xFF141416) : Colors.white;
    final baseStyle = Theme.of(context).textTheme.headlineMedium?.copyWith(
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      wordSpacing: 1.0,
      height: 1.40,
      color: textColor,
    );
    // White text glows in the song accent. A coloured glow is lost behind
    // dark letters, so dark text instead lights up in a deep shade of the
    // accent with a soft white halo, which reads on bright covers.
    final sungColor = isLight ? _deepInk(glowColor, textColor) : textColor;
    List<Shadow> glow(double strength) => isLight
        ? [
            Shadow(
              color: Colors.white.withValues(alpha: 0.85 * strength),
              blurRadius: 10.0,
            ),
            Shadow(
              color: Colors.white.withValues(alpha: 0.55 * strength),
              blurRadius: 4.0,
            ),
          ]
        : [
            Shadow(
              color: glowColor.withValues(alpha: 0.85 * strength),
              blurRadius: 8.0,
            ),
            Shadow(
              color: glowColor.withValues(alpha: 0.45 * strength),
              blurRadius: 4.0,
            ),
          ];

    final lineIndex = _activeIndex >= 0 && _activeIndex < _lyrics.length
        ? _activeIndex
        : 0;
    // Word by word unless Word Glow is off: by the line's own word timing
    // when it has it, otherwise by an estimate (see LyricsService.spansFor).
    final canSweep =
        active != null &&
        active.timed &&
        active.text.isNotEmpty &&
        LyricsDisplay.wordGlow.value != WordGlowMode.off;
    if (canSweep && _spansIndex != lineIndex) {
      _spansIndex = lineIndex;
      _spans = LyricsService.spansFor(
        _lyrics,
        lineIndex,
        onsets: LoudnessService.onsetsFor(widget.song),
      );
      _glyphs = LyricsService.glyphTimes(_spans);
    }
    final glyphs = _glyphs;
    final glowDelay = Duration(milliseconds: LyricsDisplay.glowDelayMs.value);
    if (_sweeping != canSweep) {
      _sweeping = canSweep;
      _syncSweepTicker();
    }

    // The whole line always shows: a long one (a fast rap verse) gets a
    // smaller font until it fits the card, instead of being cut off.
    Widget lineText(TextStyle? style) {
      if (!canSweep) {
        return Text(
          text,
          textAlign: TextAlign.center,
          style: style?.copyWith(shadows: glow(1)),
        );
      }
      // Each letter brightens smoothly over a moment once it is sung, so the
      // light travels through the line like a soft wave instead of switching
      // a whole word on at once; letters not yet sung wait dimmed.
      return ValueListenableBuilder<Duration>(
        valueListenable: _sweepPosition,
        builder: (context, position, _) => Text.rich(
          TextSpan(
            children: [
              for (final glyph in glyphs)
                () {
                  final t =
                      ((position - glowDelay - glyph.at).inMicroseconds /
                              _glowRampMicros)
                          .clamp(0.0, 1.0);
                  final p = t * t * (3 - 2 * t);
                  return TextSpan(
                    text: glyph.text,
                    style: TextStyle(
                      color: Color.lerp(
                        textColor.withValues(alpha: _waitingAlpha),
                        sungColor,
                        p,
                      ),
                      shadows: p > 0 ? glow(p) : null,
                    ),
                  );
                }(),
            ],
          ),
          textAlign: TextAlign.center,
          style: style,
        ),
      );
    }

    return Padding(
      // The line stays at the card's centre whether or not the visualizer is
      // on: the room kept free for its bars at the bottom is mirrored at the
      // top (which also clears the button row).
      padding: EdgeInsets.symmetric(
        vertical: widget.bottomInset > 48 ? widget.bottomInset : 48,
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: AnimatedSwitcher(
            duration: isScrubbing
                ? Duration.zero
                : const Duration(milliseconds: 140),
            switchInCurve: const Interval(0.35, 1.0, curve: Curves.easeOutQuad),
            switchOutCurve: const Interval(0.65, 1.0, curve: Curves.easeInQuad),
            layoutBuilder:
                (Widget? currentChild, List<Widget> previousChildren) {
                  return Stack(
                    alignment: Alignment.center,
                    children: <Widget>[...previousChildren, ?currentChild],
                  );
                },
            transitionBuilder: (Widget child, Animation<double> animation) {
              if (isScrubbing) return child;
              return FadeTransition(opacity: animation, child: child);
            },
            child: Container(
              key: ValueKey('pop_lyric_${widget.song.id}_$_activeIndex'),
              alignment: Alignment.center,
              // A line too tall for the room gets a smaller font, still
              // wrapping at the full width; past the smallest font it is
              // scaled down as a whole rather than running into the bars.
              child: LayoutBuilder(
                builder: (context, constraints) => FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    child: lineText(_fitToRoom(baseStyle, text, constraints)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
