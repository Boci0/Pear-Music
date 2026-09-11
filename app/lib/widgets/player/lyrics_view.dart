import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/song.dart';
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
    _loadLyrics();
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

    final lyrics = await LyricsService.getLyrics(
      widget.song,
      localAudioPath: localAudioPath,
      duration: widget.player.duration,
    );

    if (!mounted) return;

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
    final scheme = Theme.of(context).colorScheme;
    final glowColor = widget.accent ?? scheme.primary;

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
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.70),
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
                color: Colors.white.withValues(alpha: 0.50),
              ),
              const SizedBox(height: 10),
              Text(
                'No lyrics available',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
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
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.50),
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
                      foregroundColor: glowColor,
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
                      foregroundColor: glowColor,
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

    return _buildPopLyricsView(glowColor);
  }

  Widget _buildPopLyricsView(Color glowColor) {
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
          duration: isScrubbing ? Duration.zero : const Duration(milliseconds: 120),
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
            final isIncoming =
                child.key == ValueKey('pop_lyric_${widget.song.id}_$_activeIndex');

            if (isIncoming) {
              return FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutQuad,
                ),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.97, end: 1.0).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutQuad,
                    ),
                  ),
                  child: child,
                ),
              );
            } else {
              return FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0.0, 0.70, curve: Curves.easeInQuad),
                ),
                child: child,
              );
            }
          },
          child: Container(
            key: ValueKey('pop_lyric_${widget.song.id}_$_activeIndex'),
            alignment: Alignment.center,
            child: Text(
              text,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamilyFallback: const [
                  'Segoe UI Variable Text',
                  'Segoe UI',
                  'Roboto',
                  'sans-serif',
                ],
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                wordSpacing: 4.0,
                height: 1.40,
                color: Colors.white,
                shadows: [
                  Shadow(
                    color: glowColor.withValues(alpha: 0.85),
                    blurRadius: 8.0,
                  ),
                  Shadow(
                    color: glowColor.withValues(alpha: 0.45),
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

