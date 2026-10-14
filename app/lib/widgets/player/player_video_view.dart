import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../../services/video_relay.dart';
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

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: width,
          height: height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(fullscreen ? 0 : 22),
            child: ColoredBox(
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
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
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
                  else
                    const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  if (!fullscreen) ...[
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
          ),
        ),
        ValueListenableBuilder<int>(
          valueListenable: VideoRelay.bytesUsed,
          builder: (context, bytes, _) {
            final lines = video.streamHeight;
            if (lines == null || fullscreen) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                bytes <= 0
                    ? 'Streaming ${lines}p'
                    : 'Streaming ${lines}p · ${_size(bytes)} used',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
