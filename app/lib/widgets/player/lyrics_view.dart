import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/song.dart';
import '../../services/lyrics_service.dart';
import '../../services/player_service.dart';

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

class _NoScrollbarBehavior extends MaterialScrollBehavior {
  const _NoScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class _LyricsViewState extends State<LyricsView> {
  List<LyricLine> _lyrics = const [];
  bool _isLoading = true;
  int _activeIndex = -1;
  StreamSubscription<Duration>? _positionSub;
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _itemKeys = {};
  Timer? _userScrollCooldown;
  bool _isUserScrolling = false;

  @override
  void initState() {
    super.initState();
    _loadLyrics();
  }

  @override
  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id) {
      _loadLyrics();
    } else if (widget.isVisible && !oldWidget.isVisible) {
      _isUserScrolling = false;
      _snapToCurrentPosition();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _userScrollCooldown?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadLyrics() async {
    setState(() {
      _isLoading = true;
      _lyrics = const [];
      _activeIndex = -1;
      _itemKeys.clear();
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
    );

    if (!mounted) return;

    setState(() {
      _lyrics = lyrics;
      _isLoading = false;
      for (int i = 0; i < lyrics.length; i++) {
        _itemKeys[i] = GlobalKey();
      }
    });

    if (lyrics.isNotEmpty) {
      _positionSub = widget.player.positionStream.listen(_onPositionUpdate);
      _snapToCurrentPosition();
    }
  }

  void _snapToCurrentPosition() {
    if (_lyrics.isEmpty) return;
    final currentPos = widget.player.position ?? Duration.zero;
    final index = LyricsService.findActiveIndex(_lyrics, currentPos);
    if (index >= 0) {
      setState(() {
        _activeIndex = index;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToActive(index, jumpFirst: true);
      });
    }
  }

  void _onPositionUpdate(Duration position) {
    if (_lyrics.isEmpty || !mounted) return;

    final newIndex = LyricsService.findActiveIndex(_lyrics, position);
    if (newIndex != _activeIndex) {
      setState(() {
        _activeIndex = newIndex;
      });
      if (!_isUserScrolling && widget.isVisible) {
        _scrollToActive(newIndex);
      }
    }
  }

  void _scrollToActive(int index, {bool jumpFirst = false}) {
    if (index < 0 || index >= _lyrics.length) return;

    // If jumpFirst is requested or item context is not mounted yet,
    // pre-scroll close to the estimated target offset so ListView builds the item.
    if (_scrollController.hasClients && (jumpFirst || _itemKeys[index]?.currentContext == null)) {
      const estimatedItemHeight = 44.0;
      final targetOffset = (index * estimatedItemHeight);
      final clamped = targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.jumpTo(clamped);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = _itemKeys[index];
      final itemContext = key?.currentContext;
      if (itemContext != null) {
        Scrollable.ensureVisible(
          itemContext,
          alignment: 0.5,
          duration: Duration(milliseconds: jumpFirst ? 150 : 320),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }


  void _onUserScrolled() {
    _isUserScrolling = true;
    _userScrollCooldown?.cancel();
    _userScrollCooldown = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _isUserScrolling = false;
        });
        if (_activeIndex >= 0) {
          _scrollToActive(_activeIndex);
        }
      }
    });
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
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _loadLyrics,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry'),
                style: TextButton.styleFrom(
                  foregroundColor: glowColor,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final verticalSpacerHeight = widget.size * 0.42;

    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        _onUserScrolled();
        return false;
      },
      child: ShaderMask(
        shaderCallback: (Rect bounds) {
          return const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
            stops: [0.0, 0.15, 0.85, 1.0],
          ).createShader(bounds);
        },
        blendMode: BlendMode.dstIn,
        child: ScrollConfiguration(
          behavior: const _NoScrollbarBehavior(),
          child: ListView.builder(
            controller: _scrollController,
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: verticalSpacerHeight,
            ),
            itemCount: _lyrics.length,
            itemBuilder: (context, index) {
              final line = _lyrics[index];
              final isActive = index == _activeIndex;

              return Center(
                key: _itemKeys[index],
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7.0),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      widget.player.seek(line.timestamp);
                      _scrollToActive(index);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOutCubic,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: isActive ? 18.0 : 15.0,
                          fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                          height: 1.35,
                          color: isActive
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.45),
                          shadows: isActive
                              ? [
                                  Shadow(
                                    color: glowColor.withValues(alpha: 0.90),
                                    blurRadius: 18.0,
                                  ),
                                  Shadow(
                                    color: glowColor.withValues(alpha: 0.50),
                                    blurRadius: 8.0,
                                  ),
                                ]
                              : null,
                        ),
                        child: Text(
                          line.text.isEmpty ? '···' : line.text,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

  }
}
