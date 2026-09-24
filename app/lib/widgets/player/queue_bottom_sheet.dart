import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/artwork_palette.dart';
import '../../services/artwork_service.dart';
import '../../services/player_service.dart';
import '../tactile_button.dart';

/// Controller coordinating expand/collapse state between the expandable queue sheet
/// and external listeners such as the background dimming scrim.
class QueueSheetController extends ChangeNotifier {
  double _progress = 0.0;
  double _minChildSize = 0.08;
  double _expandedSize = 0.50;

  void Function()? _collapseCallback;
  void Function()? _expandCallback;
  void Function()? _toggleCallback;
  void Function(double)? _jumpCallback;

  /// Expansion progress from 0.0 (collapsed peek) to 1.0 (fully expanded).
  double get progress => _progress;

  /// Fractional sheet height relative to screen height for backward compatibility.
  double get size =>
      _minChildSize + (_expandedSize - _minChildSize) * _progress;

  double get minChildSize => _minChildSize;
  double get expandedSize => _expandedSize;
  bool get isExpanded => _progress > 0.30;
  bool get isAttached => _collapseCallback != null;

  void attach({
    required void Function() onCollapse,
    required void Function() onExpand,
    required void Function() onToggle,
    required void Function(double) onJump,
    required double minSize,
    double maxSize = 0.50,
  }) {
    _collapseCallback = onCollapse;
    _expandCallback = onExpand;
    _toggleCallback = onToggle;
    _jumpCallback = onJump;
    _minChildSize = minSize;
    _expandedSize = maxSize;
  }

  void detach() {
    _collapseCallback = null;
    _expandCallback = null;
    _toggleCallback = null;
    _jumpCallback = null;
  }

  void setProgress(double p) {
    final clamped = p.clamp(0.0, 1.0);
    if ((_progress - clamped).abs() > 0.0001) {
      _progress = clamped;
      notifyListeners();
    }
  }

  void collapse() => _collapseCallback?.call();
  void expand() => _expandCallback?.call();
  void toggle() => _toggleCallback?.call();

  Future<void> animateTo(
    double targetSize, {
    Duration duration = const Duration(milliseconds: 240),
    Curve curve = Curves.easeOutCubic,
  }) async {
    final mid = (_minChildSize + _expandedSize) / 2;
    if (targetSize <= mid) {
      collapse();
    } else {
      expand();
    }
  }

  void jumpTo(double targetSize) {
    final travel = _expandedSize - _minChildSize;
    if (travel > 0) {
      final p = ((targetSize - _minChildSize) / travel).clamp(0.0, 1.0);
      _jumpCallback?.call(p);
    }
  }
}

/// YouTube Music style pull-up queue bottom sheet with dedicated AnimationController,
/// smooth drag gesture tracking, effortless expansion threshold, and contrast-guaranteed text.
class ExpandableQueueSheet extends StatefulWidget {
  final PlayerService player;
  final AppController controller;
  final Color accent;
  final double minChildSize;
  final double? peekHeight;
  final double? maxHeight;
  final QueueSheetController sheetController;

  const ExpandableQueueSheet({
    super.key,
    required this.player,
    required this.controller,
    required this.accent,
    required this.minChildSize,
    required this.sheetController,
    this.peekHeight,
    this.maxHeight,
  });

  @override
  State<ExpandableQueueSheet> createState() => _ExpandableQueueSheetState();
}

class _ExpandableQueueSheetState extends State<ExpandableQueueSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final CurvedAnimation _curvedAnimation;
  final ScrollController _scrollController = ScrollController();

  double _dragDistance = 0.0;
  bool _hasDragged = false;

  /// Downward overscroll accumulated on the queue list, used to close the
  /// sheet when the user swipes down on the list itself (standard bottom sheet
  /// feel). Reset at the start and end of every scroll gesture.
  double _topOverscroll = 0.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: 0.0,
    );
    _curvedAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeOutCubic,
    );

    _animController.addListener(_onAnimTick);

    widget.sheetController.attach(
      onCollapse: _collapse,
      onExpand: _expand,
      onToggle: _toggle,
      onJump: _jump,
      minSize: widget.minChildSize,
      maxSize: 0.50,
    );
  }

  @override
  void didUpdateWidget(covariant ExpandableQueueSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sheetController != widget.sheetController) {
      oldWidget.sheetController.detach();
      widget.sheetController.attach(
        onCollapse: _collapse,
        onExpand: _expand,
        onToggle: _toggle,
        onJump: _jump,
        minSize: widget.minChildSize,
        maxSize: 0.50,
      );
    }
  }

  @override
  void dispose() {
    widget.sheetController.detach();
    _animController.removeListener(_onAnimTick);
    _curvedAnimation.dispose();
    _animController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onAnimTick() {
    widget.sheetController.setProgress(_animController.value);
  }

  void _collapse() {
    if (!mounted) return;
    _animController
        .animateTo(
      0.0,
      duration: const Duration(milliseconds: 230),
      curve: Curves.easeOutCubic,
    )
        .then((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(0.0);
      }
    });
  }

  void _expand() {
    if (!mounted) return;
    _animController
        .animateTo(
      1.0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    )
        .then((_) {
      if (mounted) {
        _scrollToCurrentSong(animate: true);
      }
    });
  }

  void _toggle() {
    // Decide from where the animation is heading, so a quick second tap still
    // flips the sheet instead of being swallowed mid-animation. That swallowed
    // tap is what made the card feel stuck ("locks the screen until you tap it
    // again").
    final target = _animController.isAnimating
        ? (_animController.status == AnimationStatus.forward ? 1.0 : 0.0)
        : _animController.value;
    if (target > 0.30) {
      _collapse();
    } else {
      _expand();
    }
  }

  /// A downward swipe on the list, once the list is already at its top, closes
  /// the sheet. Slow swipes deliver the overscroll in small increments, so it
  /// is accumulated rather than thresholded per notification.
  bool _onQueueScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification ||
        notification is ScrollEndNotification) {
      _topOverscroll = 0.0;
    } else if (notification is OverscrollNotification &&
        notification.overscroll < 0) {
      if (!_animController.isAnimating && _animController.value > 0.001) {
        _topOverscroll -= notification.overscroll;
        if (_topOverscroll >= 24.0) {
          _topOverscroll = 0.0;
          _collapse();
        }
      }
    }
    return false;
  }

  void _jump(double progress) {
    _animController.value = progress;
    if (progress >= 1.0) {
      _scrollToCurrentSong(animate: false);
    }
  }

  void _scrollToCurrentSong({bool animate = true}) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;

      final queue = widget.player.queue;
      if (queue.isEmpty) return;

      final currentSongId = widget.player.currentSong?.id;
      final index = currentSongId != null
          ? queue.indexWhere((s) => s.id == currentSongId)
          : widget.player.queueIndex;

      if (index < 0 || index >= queue.length) return;

      final maxScroll = _scrollController.position.maxScrollExtent;
      if (maxScroll == 0.0 && index > 2) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scrollController.hasClients) {
            _scrollToCurrentSong(animate: animate);
          }
        });
        return;
      }

      final double targetOffset;
      if (_scrollController.position.hasViewportDimension) {
        final viewportHeight = _scrollController.position.viewportDimension;
        targetOffset =
            (index * 58.0 - (viewportHeight * 0.25)).clamp(0.0, maxScroll);
      } else {
        targetOffset =
            (index > 0 ? (index - 1) * 58.0 : 0.0).clamp(0.0, maxScroll);
      }

      if ((_scrollController.offset - targetOffset).abs() > 2.0) {
        if (animate) {
          _scrollController.animateTo(
            targetOffset,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          );
        } else {
          _scrollController.jumpTo(targetOffset);
        }
      }
    });
  }

  void _handleDragStart(DragStartDetails details) {
    _dragDistance = 0.0;
    _hasDragged = false;
  }

  void _handleDragUpdate(DragUpdateDetails details, double travel) {
    if (travel <= 0) return;
    final delta = details.primaryDelta ?? 0.0;
    _dragDistance += delta.abs();
    if (_dragDistance > 4.0) {
      _hasDragged = true;
      final nextValue =
          (_animController.value - (delta / travel)).clamp(0.0, 1.0);
      _animController.value = nextValue;
    }
  }

  void _handleDragEnd(DragEndDetails details) {
    if (!_hasDragged) {
      return;
    }
    final vy = details.primaryVelocity ?? 0.0;
    if (vy < -150) {
      _expand();
    } else if (vy > 150) {
      _collapse();
    } else {
      if (_animController.value >= 0.30) {
        _expand();
      } else {
        _collapse();
      }
    }
  }

  /// The queue list, rebuilt fresh whenever the sheet rebuilds so the sheet
  /// can wrap it in different hit-test layers while animating.
  Widget _buildQueueList() {
    return _QueueListView(
      player: widget.player,
      accent: widget.accent,
      scrollController: _scrollController,
      onSelectSong: (song, queue, index) {
        _collapse();
        widget.player.playSong(
          song,
          queue: queue,
          sourceId: widget.player.queueSourceId,
          initialIndex: index,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final totalHeight = mediaQuery.size.height;
    final bottomInset = mediaQuery.padding.bottom;

    final peek = widget.peekHeight ??
        math.max(63.0, (widget.minChildSize * totalHeight) + bottomInset);
    final maxH = widget.maxHeight ?? (totalHeight * 0.50);
    final travel = math.max(1.0, maxH - peek);

    return AnimatedBuilder(
      animation: _curvedAnimation,
      builder: (context, _) {
        final currentHeight =
            lerpDouble(peek, maxH, _curvedAnimation.value)!;
        final isExpanded = _animController.value > 0.30;

        return Container(
          height: currentHeight,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xFF151518),
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(lerpDouble(22, 28, _curvedAnimation.value)!),
            ),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(
                  alpha: lerpDouble(0.12, 0.05, _curvedAnimation.value)!,
                ),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: lerpDouble(0.40, 0.65, _curvedAnimation.value)!,
                ),
                blurRadius: lerpDouble(16, 28, _curvedAnimation.value)!,
                spreadRadius: 1,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            children: [
              // Unified Header bar with drag handle and toolbar
              _QueueHeaderWidget(
                player: widget.player,
                accent: widget.accent,
                isExpanded: isExpanded,
                onToggle: _toggle,
                onDragStart: _handleDragStart,
                onDragUpdate: (details) => _handleDragUpdate(details, travel),
                onDragEnd: _handleDragEnd,
              ),

              if (_animController.value > 0.001) ...[
                const Divider(height: 1, color: Color(0x1AFFFFFF)),

                // Scrollable queue list. While the sheet animates, taps in the
                // list area flip the sheet back instead of selecting a row
                // that slid under the cursor. That is what made a quick second
                // tap on the peek card feel dead, or accidentally start a song.
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onQueueScroll,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _buildQueueList(),
                        if (_animController.isAnimating)
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _toggle,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _QueueHeaderWidget extends StatefulWidget {
  final PlayerService player;
  final Color accent;
  final bool isExpanded;
  final VoidCallback onToggle;
  final void Function(DragStartDetails) onDragStart;
  final void Function(DragUpdateDetails) onDragUpdate;
  final void Function(DragEndDetails) onDragEnd;

  const _QueueHeaderWidget({
    required this.player,
    required this.accent,
    required this.isExpanded,
    required this.onToggle,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  State<_QueueHeaderWidget> createState() => _QueueHeaderWidgetState();
}

class _QueueHeaderWidgetState extends State<_QueueHeaderWidget> {
  bool _isHandleHovered = false;

  Color get _readableAccent => ArtworkPalette.readableAccent(widget.accent);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60.0,
      color: const Color(0xFF151518),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: widget.onDragStart,
        onVerticalDragUpdate: widget.onDragUpdate,
        onVerticalDragEnd: widget.onDragEnd,
        onTap: widget.onToggle,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Centered drag handle indicator (hover highlight without nested tap detector)
            Center(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _isHandleHovered = true),
                onExit: (_) => setState(() => _isHandleHovered = false),
                child: Container(
                  padding: const EdgeInsets.only(
                    top: 6,
                    bottom: 6,
                    left: 48,
                    right: 48,
                  ),
                  color: Colors.transparent,
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: _isHandleHovered
                          ? Colors.white.withValues(alpha: 0.65)
                          : Colors.white.withValues(alpha: 0.32),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),

            // Header row switching smoothly between collapsed peek and full toolbar
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: ListenableBuilder(
                  listenable: widget.player,
                  builder: (context, _) {
                    final queue = widget.player.queue;
                    final currentSongId = widget.player.currentSong?.id;
                    final currentIndex = currentSongId != null
                        ? queue.indexWhere((s) => s.id == currentSongId)
                        : widget.player.queueIndex;
                    final nextIndex = currentIndex >= 0 ? currentIndex + 1 : -1;
                    final nextSong =
                        (nextIndex >= 0 && nextIndex < queue.length) ? queue[nextIndex] : null;

                    if (widget.isExpanded) {
                      return _buildExpandedToolbar(context, queue.length);
                    } else {
                      return _buildCollapsedPeek(
                          context, queue.length, nextSong);
                    }
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollapsedPeek(
      BuildContext context, int queueLength, Song? nextSong) {
    return Row(
      children: [
        Icon(Icons.queue_music_rounded, size: 18, color: _readableAccent),
        const SizedBox(width: 8),
        Text(
          'UP NEXT',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
            color: _readableAccent,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: _readableAccent.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '$queueLength',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: _readableAccent,
            ),
          ),
        ),
        if (nextSong != null) ...[
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              nextSong.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.65),
              ),
            ),
          ),
        ] else ...[
          const Spacer(),
        ],
      ],
    );
  }

  Widget _buildExpandedToolbar(BuildContext context, int queueLength) {
    return Row(
      children: [
        Icon(Icons.queue_music_rounded, size: 20, color: _readableAccent),
        const SizedBox(width: 8),
        Text(
          'Up Next',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: -0.2,
              ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: _readableAccent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '$queueLength',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: _readableAccent,
            ),
          ),
        ),
        const Spacer(),

        // Autoplay toggle chip
        InkWell(
          onTap: () {
            TactileFeedback.selection();
            widget.player.setAutoplay(!widget.player.autoplay);
          },
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: widget.player.autoplay
                  ? _readableAccent.withValues(alpha: 0.20)
                  : Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 13,
                  color: widget.player.autoplay
                      ? _readableAccent
                      : Colors.white.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 4),
                Text(
                  'Endless Play',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: widget.player.autoplay
                        ? _readableAccent
                        : Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(width: 4),

        // Reroll recommendations button (2 states: manual reroll vs continuous auto-reroll on track change)
        ListenableBuilder(
          listenable: widget.player,
          builder: (context, _) {
            final active = widget.player.autoRerollSeed;
            return Tooltip(
              message: active
                  ? 'Auto-reroll seed: ON (tap to turn OFF)'
                  : 'Auto-reroll seed: OFF (tap to turn ON; long press to reroll once)',
              child: InkWell(
                onTap: () {
                  TactileFeedback.click();
                  widget.player.toggleAutoRerollSeed();
                },
                onLongPress: () {
                  TactileFeedback.selection();
                  widget.player.rerollUpcomingQueue();
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: active
                        ? _readableAccent.withValues(alpha: 0.20)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    active ? Icons.casino_rounded : Icons.casino_outlined,
                    size: 18,
                    color: active
                        ? _readableAccent
                        : _readableAccent.withValues(alpha: 0.6),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Static queue panel for very wide windows: the same queue list and controls
/// as the expanded sheet, pinned as a full-height card instead of a pull-up
/// sheet.
class PlayerQueuePanel extends StatefulWidget {
  final PlayerService player;
  final Color accent;

  const PlayerQueuePanel({
    super.key,
    required this.player,
    required this.accent,
  });

  @override
  State<PlayerQueuePanel> createState() => _PlayerQueuePanelState();
}

class _PlayerQueuePanelState extends State<PlayerQueuePanel> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final readableAccent = ArtworkPalette.readableAccent(widget.accent);

    return Container(
      key: const ValueKey('queue_panel'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF151518),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: ListenableBuilder(
              listenable: widget.player,
              builder: (context, _) {
                final queueLength = widget.player.queue.length;
                final autoplay = widget.player.autoplay;
                return Row(
                  children: [
                    Icon(
                      Icons.queue_music_rounded,
                      size: 20,
                      color: readableAccent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Up Next',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: readableAccent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$queueLength',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: readableAccent,
                        ),
                      ),
                    ),
                    const Spacer(),

                    // Endless Play toggle
                    InkWell(
                      onTap: () {
                        TactileFeedback.selection();
                        widget.player.setAutoplay(!autoplay);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: autoplay
                              ? readableAccent.withValues(alpha: 0.20)
                              : Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.auto_awesome_rounded,
                              size: 13,
                              color: autoplay
                                  ? readableAccent
                                  : Colors.white.withValues(alpha: 0.5),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Endless',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: autoplay
                                    ? readableAccent
                                    : Colors.white.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),

                    // Reroll recommendations
                    ListenableBuilder(
                      listenable: widget.player,
                      builder: (context, _) {
                        final active = widget.player.autoRerollSeed;
                        return Tooltip(
                          message: active
                              ? 'Auto-reroll seed: ON (tap to turn OFF)'
                              : 'Auto-reroll seed: OFF (tap to turn ON; long press to reroll once)',
                          child: InkWell(
                            onTap: () {
                              TactileFeedback.click();
                              widget.player.toggleAutoRerollSeed();
                            },
                            onLongPress: () {
                              TactileFeedback.selection();
                              widget.player.rerollUpcomingQueue();
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.all(5),
                              decoration: BoxDecoration(
                                color: active
                                    ? readableAccent.withValues(alpha: 0.20)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                active
                                    ? Icons.casino_rounded
                                    : Icons.casino_outlined,
                                size: 18,
                                color: active
                                    ? readableAccent
                                    : readableAccent.withValues(alpha: 0.6),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ),
          const Divider(height: 1, color: Color(0x1AFFFFFF)),
          Expanded(
            child: _QueueListView(
              player: widget.player,
              accent: widget.accent,
              scrollController: _scrollController,
              onSelectSong: (song, queue, index) {
                widget.player.playSong(
                  song,
                  queue: queue,
                  sourceId: widget.player.queueSourceId,
                  initialIndex: index,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueListView extends StatelessWidget {
  final PlayerService player;
  final Color accent;
  final ScrollController scrollController;
  final void Function(Song song, List<Song> queue, int index) onSelectSong;

  const _QueueListView({
    required this.player,
    required this.accent,
    required this.scrollController,
    required this.onSelectSong,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final queue = player.queue;
        final currentSongId = player.currentSong?.id;
        final currentIndex = player.queueIndex;

        if (queue.isEmpty) {
          return Center(
            child: Text(
              'Queue is empty',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white54),
            ),
          );
        }

        return ListView.builder(
          controller: scrollController,
          itemExtent: 58.0,
          padding: const EdgeInsets.only(bottom: 16),
          itemCount: queue.length,
          itemBuilder: (context, i) {
            final song = queue[i];
            final isCurrent = currentSongId != null
                ? song.id == currentSongId
                : i == currentIndex;

            return _QueueRow(
              key: ValueKey('queue_row_${song.id}_$i'),
              song: song,
              index: i,
              isCurrent: isCurrent,
              accent: accent,
              onTap: () => onSelectSong(song, queue, i),
              onRemove: () => player.removeFromQueue(i),
            );
          },
        );
      },
    );
  }
}

class _QueueRow extends StatelessWidget {
  final Song song;
  final int index;
  final bool isCurrent;
  final Color accent;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _QueueRow({
    super.key,
    required this.song,
    required this.index,
    required this.isCurrent,
    required this.accent,
    required this.onTap,
    required this.onRemove,
  });

  Color get _readableAccent => ArtworkPalette.readableAccent(accent);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final readableAccent = _readableAccent;

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: () {
            TactileFeedback.click();
            onTap();
          },
          borderRadius: BorderRadius.circular(10),
          hoverColor: Colors.white.withValues(alpha: 0.05),
          child: Container(
            height: 55,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: isCurrent
                  ? readableAccent.withValues(alpha: 0.14)
                  : Colors.transparent,
            ),
            child: Row(
              children: [
                // Track Number or Active indicator bar
                SizedBox(
                  width: 38,
                  child: Center(
                    child: isCurrent
                        ? Container(
                            width: 3,
                            height: 18,
                            decoration: BoxDecoration(
                              color: readableAccent,
                              borderRadius: BorderRadius.circular(1.5),
                            ),
                          )
                        : Text(
                            '${index + 1}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.40),
                            ),
                          ),
                  ),
                ),

                // Artwork Thumbnail
                _QueueArtworkThumbnail(
                  song: song,
                  isCurrent: isCurrent,
                  accent: readableAccent,
                ),

                const SizedBox(width: 12),

                // Song Title & Details
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isCurrent
                              ? readableAccent
                              : Colors.white.withValues(alpha: 0.9),
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.sizeLabel,
                        maxLines: 1,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11.5,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),

                // Remove button for non-playing tracks
                if (!isCurrent)
                  TactileIconButton(
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Remove from queue',
                    icon: Icon(
                      Icons.close_rounded,
                      color: Colors.white.withValues(alpha: 0.60),
                    ),
                    onPressed: onRemove,
                  ),
              ],
            ),
          ),
        ),
      ),
    ));
  }
}

class _QueueArtworkThumbnail extends StatefulWidget {
  final Song song;
  final bool isCurrent;
  final Color accent;

  const _QueueArtworkThumbnail({
    required this.song,
    required this.isCurrent,
    required this.accent,
  });

  @override
  State<_QueueArtworkThumbnail> createState() => _QueueArtworkThumbnailState();
}

class _QueueArtworkThumbnailState extends State<_QueueArtworkThumbnail> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _loadArtwork();
  }

  @override
  void didUpdateWidget(covariant _QueueArtworkThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id) {
      _loadArtwork();
    }
  }

  void _loadArtwork() {
    final art = widget.song.artwork;
    if (art == null || art.isEmpty) {
      _bytes = null;
      return;
    }
    if (art.startsWith('http')) {
      _bytes = null;
      return;
    }
    final cached = ArtworkPalette.bytes(widget.song);
    if (cached != null) {
      _bytes = cached;
      return;
    }
    ArtworkPalette.bytesAsync(widget.song).then((decoded) {
      if (mounted && decoded != null) {
        setState(() => _bytes = decoded);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final art = widget.song.artwork;
    final isNetwork = art != null && art.startsWith('http');

    if (_bytes != null && _bytes!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(
          _bytes!,
          width: 38,
          height: 38,
          cacheWidth: 96,
          
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _placeholder(),
        ),
      );
    }

    if (isNetwork) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(
          ArtworkService.optimizeArtworkUrl(art),
          width: 38,
          height: 38,
          cacheWidth: 96,
          
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _placeholder(),
        ),
      );
    }

    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        widget.isCurrent ? Icons.music_note : Icons.audiotrack,
        size: 18,
        color: widget.isCurrent ? widget.accent : Colors.white54,
      ),
    );
  }
}
