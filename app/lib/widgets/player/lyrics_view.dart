import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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
  final bool popMode;

  const LyricsView({
    super.key,
    required this.song,
    required this.player,
    this.accent,
    required this.size,
    this.isVisible = true,
    this.popMode = false,
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
    } else if (oldWidget.popMode != widget.popMode) {
      if (!widget.popMode) {
        _snapToCurrentPosition(immediate: true);
      }
    } else if (widget.isVisible && !oldWidget.isVisible) {
      _isUserScrolling = false;
      if (!widget.popMode) {
        _snapToCurrentPosition(immediate: true);
      }
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
      _snapToCurrentPosition(immediate: true);
    }
  }

  void _snapToCurrentPosition({bool immediate = false}) {
    if (_lyrics.isEmpty) return;
    final currentPos = widget.player.position ?? Duration.zero;
    final index = LyricsService.findActiveIndex(_lyrics, currentPos);
    if (index >= 0) {
      setState(() {
        _activeIndex = index;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToActive(index, immediate: immediate);
      });
    }
  }

  void _onPositionUpdate(Duration position) {
    if (_lyrics.isEmpty || !mounted) return;

    final newIndex = LyricsService.findActiveIndex(_lyrics, position);
    if (newIndex != _activeIndex) {
      final oldIndex = _activeIndex;
      setState(() {
        _activeIndex = newIndex;
      });
      if (!widget.popMode && !_isUserScrolling && widget.isVisible) {
        final distance = (newIndex - oldIndex).abs();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToActive(newIndex, immediate: distance > 6);
        });
      }
    }
  }

  void _scrollToActive(int index, {bool immediate = false}) {
    if (index < 0 || index >= _lyrics.length || !_scrollController.hasClients) return;

    final itemContext = _itemKeys[index]?.currentContext;
    if (itemContext == null) return;
    final renderBox = itemContext.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;

    final viewport = RenderAbstractViewport.of(renderBox);

    // alignment 0.5 aligns the exact vertical midpoint of renderBox
    // with the exact vertical midpoint of the scrollable viewport.
    final revealedOffset = viewport.getOffsetToReveal(renderBox, 0.5).offset;
    final targetOffset = revealedOffset.clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );

    if (immediate) {
      _scrollController.jumpTo(targetOffset);
    } else {
      final currentOffset = _scrollController.offset;
      final diff = (targetOffset - currentOffset).abs();
      // If jumping a substantial distance, jump closer first to avoid disorienting blur
      if (diff > 450) {
        final jumpNear = targetOffset > currentOffset
            ? targetOffset - 150
            : targetOffset + 150;
        _scrollController.jumpTo(
          jumpNear.clamp(0.0, _scrollController.position.maxScrollExtent),
        );
      }
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onUserScrolled() {
    _isUserScrolling = true;
    _userScrollCooldown?.cancel();
    _userScrollCooldown = Timer(const Duration(milliseconds: 3500), () {
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

    if (widget.popMode) {
      return _buildPopLyricsView(glowColor);
    }
    return _buildClassicScrollView(glowColor);
  }

  Widget _buildPopLyricsView(Color glowColor) {
    final active = (_activeIndex >= 0 && _activeIndex < _lyrics.length)
        ? _lyrics[_activeIndex]
        : (_lyrics.isNotEmpty ? _lyrics[0] : null);

    final text = (active == null || active.text.isEmpty) ? '···' : active.text;

    final scale = (widget.size / 300.0).clamp(0.90, 1.35);
    final double baseFontSize;
    if (text.length <= 20) {
      baseFontSize = 26.0;
    } else if (text.length <= 45) {
      baseFontSize = 23.0;
    } else if (text.length <= 70) {
      baseFontSize = 20.5;
    } else {
      baseFontSize = 18.0;
    }
    final fontSize = (baseFontSize * scale).roundToDouble();

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
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
            final isIncoming =
                child.key == ValueKey('pop_lyric_${widget.song.id}_$_activeIndex');

            if (isIncoming) {
              return FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0.35, 1.0, curve: Curves.easeOutCubic),
                ),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.92, end: 1.0).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: const Interval(0.35, 1.0, curve: Curves.easeOutCubic),
                    ),
                  ),
                  child: child,
                ),
              );
            } else {
              return FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0.65, 1.0, curve: Curves.easeInCubic),
                ),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 1.0, end: 0.94).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: const Interval(0.65, 1.0, curve: Curves.easeInCubic),
                    ),
                  ),
                  child: child,
                ),
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

  Widget _buildClassicScrollView(Color glowColor) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;
        // Half height padding ensures every line (from first to last)
        // can be scrolled to the exact vertical center.
        final halfHeight = viewportHeight / 2;

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
              child: SingleChildScrollView(
                controller: _scrollController,
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: (halfHeight - 22).clamp(0.0, halfHeight),
                  bottom: (halfHeight - 22).clamp(0.0, halfHeight),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (int i = 0; i < _lyrics.length; i++)
                      _buildLyricLine(i, glowColor),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLyricLine(int index, Color glowColor) {
    final line = _lyrics[index];
    final isActive = index == _activeIndex;

    final scrollScale = (widget.size / 300.0).clamp(0.90, 1.25);
    final activeFontSize = (19.0 * scrollScale).roundToDouble();
    final inactiveFontSize = (17.0 * scrollScale).roundToDouble();

    return Center(
      key: _itemKeys[index],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            widget.player.seek(line.timestamp);
            setState(() {
              _activeIndex = index;
            });
            _scrollToActive(index);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 6,
            ),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamilyFallback: const [
                  'Segoe UI Variable Text',
                  'Segoe UI',
                  'Roboto',
                  'sans-serif',
                ],
                fontSize: isActive ? activeFontSize : inactiveFontSize,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                letterSpacing: 0.2,
                wordSpacing: 3.5,
                height: 1.40,
                color: isActive
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.35),
                shadows: isActive
                    ? [
                        Shadow(
                          color: glowColor.withValues(alpha: 0.85),
                          blurRadius: 8.0,
                        ),
                        Shadow(
                          color: glowColor.withValues(alpha: 0.45),
                          blurRadius: 4.0,
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
  }
}
