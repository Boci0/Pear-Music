import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../models/song.dart';
import '../../services/player_service.dart';
import '../../services/video_service.dart';
import '../system_bars.dart';
import 'player_controls.dart';
import 'player_video_view.dart';

/// The video of the playing song filling the whole screen. Tapping brings up
/// a close button, the title and the usual seek bar and transport for a few
/// seconds; back or Escape leaves. It closes itself when there is no video
/// to show (the song changed to one without a picture, or the video was
/// turned off).
class PlayerFullscreenPage extends StatefulWidget {
  const PlayerFullscreenPage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, _, _) => const PlayerFullscreenPage(),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  /// Whether a [picture] shape on a [screen] shape fills it by default: the
  /// share of the picture that filling would crop away is small enough to be
  /// worth having no bars (a long phone screen is not).
  @visibleForTesting
  static bool fillsByDefault(double picture, double screen) {
    final cropped = 1 - math.min(screen, picture) / math.max(screen, picture);
    return cropped <= 0.25;
  }

  @override
  State<PlayerFullscreenPage> createState() => _PlayerFullscreenPageState();
}

class _PlayerFullscreenPageState extends State<PlayerFullscreenPage> {
  static const Duration _hideAfter = Duration(seconds: 3);

  bool _controls = true;
  bool _immersive = false;

  /// Fill (crop the edges to cover the screen) or fit (whole picture, bars);
  /// null lets the shape of the screen against the picture decide.
  bool? _fill;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    final mobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (mobile) {
      _immersive = true;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      // A video is wide: turn a phone held upright so it fills the screen.
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    _armHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    if (_immersive) {
      SystemBars.restore();
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    super.dispose();
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideAfter, () {
      if (mounted) setState(() => _controls = false);
    });
  }

  void _toggle() {
    setState(() => _controls = !_controls);
    if (_controls) _armHide();
  }

  // Every rebuild with no video to show schedules a close; once the page is
  // on its way out a second pop would take the screen underneath with it.
  bool _closing = false;

  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final song = context.select<PlayerService, Song?>((p) => p.currentSong);
    final video = context.watch<VideoService?>();
    if (song == null || !(video?.showingFor(song) ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _close();
      });
      return const Scaffold(backgroundColor: Colors.black);
    }
    final player = context.read<PlayerService>();
    final controller = context.read<AppController>();
    final duration = context.select<PlayerService, Duration>(
      (p) => p.duration ?? Duration.zero,
    );
    final size = MediaQuery.sizeOf(context);
    final accent = Theme.of(context).colorScheme.primary;
    // The picture's own shape (bars the video carries are already trimmed).
    final aspect =
        (video!.frameAspect ?? 16 / 9) * (video.crop.width / video.crop.height);
    final fill =
        _fill ?? PlayerFullscreenPage.fillsByDefault(aspect, size.aspectRatio);

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: fill
                      ? ClipRect(
                          child: SizedBox(
                            width: size.width,
                            height: size.height,
                            child: FittedBox(
                              fit: BoxFit.cover,
                              child: PlayerVideoView(
                                accent: accent,
                                maxWidth: aspect * 1000,
                                maxHeight: 1000,
                                fullscreen: true,
                              ),
                            ),
                          ),
                        )
                      : PlayerVideoView(
                          accent: accent,
                          maxWidth: size.width,
                          maxHeight: size.height,
                          fullscreen: true,
                        ),
                ),
                AnimatedOpacity(
                  opacity: _controls ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_controls,
                    // Using a control keeps them up, so they do not vanish
                    // under a finger a moment after a tap.
                    child: Listener(
                      onPointerDown: (_) => _armHide(),
                      child: Column(
                        children: [
                          DecoratedBox(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0xCC000000), Color(0x00000000)],
                              ),
                            ),
                            child: SafeArea(
                              bottom: false,
                              child: Row(
                                children: [
                                  IconButton(
                                    tooltip: 'Exit fullscreen',
                                    icon: const Icon(
                                      Icons.fullscreen_exit_rounded,
                                      color: Colors.white,
                                    ),
                                    onPressed: _close,
                                  ),
                                  Expanded(
                                    child: Text(
                                      song.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(color: Colors.white),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: fill
                                        ? 'Show the whole picture'
                                        : 'Fill the screen',
                                    icon: Icon(
                                      fill
                                          ? Icons.fit_screen_rounded
                                          : Icons.aspect_ratio_rounded,
                                      color: Colors.white,
                                    ),
                                    onPressed: () =>
                                        setState(() => _fill = !fill),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                              ),
                            ),
                          ),
                          const Spacer(),
                          DecoratedBox(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [Color(0xCC000000), Color(0x00000000)],
                              ),
                            ),
                            child: SafeArea(
                              top: false,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  16,
                                  24,
                                  8,
                                ),
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 560,
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        PlayerSeekBar(
                                          player: player,
                                          duration: duration,
                                          accent: accent,
                                        ),
                                        PlayerTransport(
                                          player: player,
                                          controller: controller,
                                          accent: accent,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
