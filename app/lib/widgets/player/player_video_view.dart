import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../services/video_relay.dart';
import '../../theme/tokens.dart';
import '../../services/video_service.dart';
import 'player_artwork.dart';
import 'player_fullscreen.dart';

/// The picture of the playing song, in the artwork's place, as large as fits
/// [maxWidth] by [maxHeight] in its own shape (black bars the video carries
/// are trimmed, see `VideoService.crop`). The player's own controls stay the
/// only controls; this adds only the way back to the artwork and, for a
/// streamed picture, what it has used so far, as the livestream shows.
class PlayerVideoView extends StatelessWidget {
  final Color accent;
  final double maxWidth;
  final double maxHeight;

  /// Shown by the full-screen page: square corners, no caption and no
  /// buttons over the picture (the page has its own).
  final bool fullscreen;

  const PlayerVideoView({
    super.key,
    required this.accent,
    required this.maxWidth,
    required this.maxHeight,
    this.fullscreen = false,
  });

  static String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).round()} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final video = context.watch<VideoService>();
    final controller = video.controller;
    final crop = video.crop;
    final frame = video.frameAspect ?? 16 / 9;
    final aspect = frame * (crop.width / crop.height);
    final width = math.min(maxWidth, maxHeight * aspect);
    final height = width / aspect;
    final fullWidth = width / crop.width;
    final fullHeight = height / crop.height;
    final radius = BorderRadius.circular(fullscreen ? 0 : PearRadius.sheet);
    final reducedEffects = context.select<AppController?, bool>(
      (c) => c?.identity.reducedEffects ?? false,
    );
    // The card's edge dissolves into its accent glow, as the artwork's does.
    // The fade is two mask layers over a playing picture, so reduced effects
    // and phones (where that costs battery) keep a plain outline instead.
    // Reduced effects also drops the glow for a plain drop shadow.
    final phone =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final feathered = !fullscreen && !reducedEffects && !phone;

    final BoxDecoration edge;
    if (fullscreen) {
      edge = const BoxDecoration();
    } else if (!reducedEffects) {
      // The glow is a static shadow in its own repaint boundary, cheap enough
      // for phones; only the edge fade over the playing picture is not.
      edge = BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.30),
            blurRadius: 36,
            offset: const Offset(0, 10),
            spreadRadius: 2,
          ),
          BoxShadow(
            color: accent.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 4),
            spreadRadius: 1,
          ),
        ],
      );
    } else {
      edge = BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.30),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      );
    }

    final picture = ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null)
            OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: fullWidth,
              maxWidth: fullWidth,
              minHeight: fullHeight,
              maxHeight: fullHeight,
              child: FractionalTranslation(
                translation: Offset(-crop.left, -crop.top),
                child: Video(
                  controller: controller,
                  controls: NoVideoControls,
                  fill: Colors.black,
                ),
              ),
            )
          else if (video.failure != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      video.failure!,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.75),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: video.retry,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            )
          else if (video.isShown)
            const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: width,
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // The glow is its own layer, so a new video frame does not
              // re-record the blurred shadows.
              Positioned.fill(
                child: RepaintBoundary(child: DecoratedBox(decoration: edge)),
              ),
              ClipRRect(
                borderRadius: radius,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    feathered ? EdgeFeather(child: picture) : picture,
                    if (!fullscreen) ...[
                      if (!feathered)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: radius,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.16),
                                ),
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        top: 10,
                        left: 10,
                        child: PlayerPillButton(
                          isCircle: true,
                          activeColor: accent,
                          tooltip: 'Fullscreen',
                          onTap: () => PlayerFullscreenPage.open(context),
                          child: const Icon(
                            Icons.fullscreen_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      Positioned(
                        top: 10,
                        right: 10,
                        child: PlayerPillButton(
                          isCircle: true,
                          activeColor: accent,
                          tooltip: 'Show album artwork',
                          onTap: video.hide,
                          child: const Icon(
                            Icons.image_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        ValueListenableBuilder<int>(
          valueListenable: VideoRelay.bytesUsed,
          builder: (context, bytes, _) {
            if (fullscreen) return const SizedBox.shrink();
            // A picture read from disk moves no network bytes: it shows its
            // own size instead, so the line under the picture is never empty
            // and never reuses a previous stream's total.
            final String label;
            if (video.streamPicture) {
              final lines = video.streamHeight;
              if (lines == null) return const SizedBox.shrink();
              label = bytes <= 0
                  ? 'Streaming ${lines}p'
                  : 'Streaming ${lines}p · ${_size(bytes)} used';
            } else {
              final size = video.pictureSize;
              if (size == null) return const SizedBox.shrink();
              label = '${size.width}x${size.height} · from this device';
            }
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.72),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Cross-fades the artwork card and the video picture and eases the size
/// change between them (square cover, wide picture) instead of a jump cut.
/// The caller picks the child; [video] keys the switch. Size changes that are
/// not a swap (a resized window) are not animated.
class PlayerPictureSwap extends StatefulWidget {
  final bool video;
  final Widget child;
  const PlayerPictureSwap({
    super.key,
    required this.video,
    required this.child,
  });

  @override
  State<PlayerPictureSwap> createState() => _PlayerPictureSwapState();
}

class _PlayerPictureSwapState extends State<PlayerPictureSwap> {
  static const _fade = Duration(milliseconds: 220);
  static const _ease = Duration(milliseconds: 240);

  DateTime _swappedAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void didUpdateWidget(PlayerPictureSwap old) {
    super.didUpdateWidget(old);
    if (old.video != widget.video) _swappedAt = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final swapping = DateTime.now().difference(_swappedAt) < _ease * 2;
    return AnimatedSize(
      duration: swapping ? _ease : Duration.zero,
      curve: Curves.easeOutCubic,
      // The artwork's glow paints outside its box.
      clipBehavior: Clip.none,
      child: AnimatedSwitcher(
        duration: _fade,
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        // Only the incoming child sizes the stack, so the box eases once to
        // its size; the outgoing one fades at its own size over it.
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            for (final old in previous)
              Positioned.fill(
                child: IgnorePointer(
                  child: OverflowBox(
                    minWidth: 0,
                    minHeight: 0,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    child: old,
                  ),
                ),
              ),
            ?current,
          ],
        ),
        child: KeyedSubtree(key: ValueKey(widget.video), child: widget.child),
      ),
    );
  }
}
