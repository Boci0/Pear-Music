import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'controllers/app_controller.dart';
import 'screens/home_shell.dart';
import 'services/debug_log.dart';
import 'services/identity_service.dart';
import 'services/library_service.dart';
import 'services/pear_audio_handler.dart';
import 'services/player_service.dart';
import 'services/player_theme.dart';
import 'services/youtube_service.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Clamp Flutter image cache to 25 MB to prevent high memory usage on mobile devices
    PaintingBinding.instance.imageCache.maximumSizeBytes = 25 * 1024 * 1024;
    PaintingBinding.instance.imageCache.maximumSize = 80;

    // Mirror every debugPrint into a rotating peerm_debug.log file so release
    // builds (no console on Windows) can still be diagnosed in the field:
    // post-transfer lag, resend loops and reconnect churn all leave traces.
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) DebugLog.write(message);
      originalDebugPrint(message, wrapWidth: wrapWidth);
    };

    // Replace default error widget with a resilient fallback UI
    ErrorWidget.builder = (FlutterErrorDetails details) {
      return PearMusicErrorWidget(details: details);
    };

    // Enables the media_kit backend for Windows audio playback.
    try {
      JustAudioMediaKit.ensureInitialized();
    } catch (e) {
      debugPrint('[pearmusic] JustAudioMediaKit.ensureInitialized error: $e');
    }

    // Swallow + log any unhandled async/plugin exception instead of letting it
    // take the app down.
    FlutterError.onError = (details) {
      debugPrint('[pearmusic] FlutterError: ${details.exception}');
      debugPrint('[pearmusic] ${details.toString()}');
      debugPrint('[pearmusic] ${details.stack}');
    };
    WidgetsBinding.instance.platformDispatcher.onError =
        (Object error, StackTrace stack) {
      debugPrint('[pearmusic] Unhandled platform exception: $error');
      debugPrint('[pearmusic] $stack');
      return true; // handled (keep the app alive)
    };

    try {
      await _bootstrapAndRunApp();
    } catch (error, stack) {
      debugPrint('[pearmusic] Bootstrap initialization error: $error');
      debugPrint('[pearmusic] $stack');
      runApp(
        PearMusicBootstrapErrorApp(
          error: error,
          stackTrace: stack,
          onRetry: () => _bootstrapAndRunApp(),
        ),
      );
    }
  }, (error, stack) {
    debugPrint('[pearmusic] Uncaught zone exception: $error');
    debugPrint('[pearmusic] $stack');
  });
}

Future<void> _bootstrapAndRunApp() async {
  // On Android, host the media notification (play/pause + next/previous + lock
  // screen) via PearAudioHandler and audio_service. Windows stays on media_kit
  // and gets no notification (it is a desktop app).
  PearAudioHandler? audioHandler;
  if (Platform.isAndroid) {
    try {
      audioHandler = await AudioService.init(
        builder: () => PearAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.peerm.peerm_app.channel.audio',
          androidNotificationChannelName: 'Audio playback',
          androidNotificationIcon: 'mipmap/ic_notification',
          androidStopForegroundOnPause: false,
          androidNotificationOngoing: false,
        ),
      );
    } catch (e) {
      debugPrint('[pearmusic] AudioService.init error: $e');
    }
  }

  final prefs = await SharedPreferences.getInstance();
  final identity = IdentityService(prefs);
  final library = LibraryService();
  final player = PlayerService(
    library,
    identity: identity,
    audioHandler: audioHandler,
  );
  final youtube = YoutubeService();
  unawaited(YoutubeService.checkDesktopYtDlpUpdate());

  final controller = AppController(
    identity: identity,
    library: library,
    player: player,
    youtube: youtube,
  );
  await controller.init();

  // App-wide theme that follows the currently-playing song's artwork colour.
  final playerTheme = PlayerTheme(player);
  runApp(PearMusicApp(controller: controller, playerTheme: playerTheme));
}

class PearMusicApp extends StatelessWidget {
  final AppController controller;
  final PlayerTheme playerTheme;
  const PearMusicApp({
    super.key,
    required this.controller,
    required this.playerTheme,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        ChangeNotifierProvider<LibraryService>.value(value: controller.library),
        ChangeNotifierProvider<PlayerService>.value(value: controller.player),
        ChangeNotifierProvider<PlayerTheme>.value(value: playerTheme),
      ],
      // The whole app's theme is re-seeded from the current song's artwork
      // colour (dark mode preserved), so the colour follows the music app-wide
      // (not just on the player). AnimatedTheme fades between themes when the
      // song changes so the colour shift is graceful, not a hard snap.
      child: Builder(
        builder: (context) {
          final theme = context.watch<PlayerTheme>().theme;
          return MaterialApp(
            title: 'Pear Music',
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: const _MessagesListener(child: HomeShell()),
          );
        },
      ),
    );
  }
}

/// Resilient error widget used when widget tree rendering fails.
class PearMusicErrorWidget extends StatelessWidget {
  final FlutterErrorDetails details;
  const PearMusicErrorWidget({super.key, required this.details});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Colors.amber,
                size: 28,
              ),
              const SizedBox(height: 6),
              const Text(
                'Unable to display this item',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.white70,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fallback recovery UI shown if application initialization fails during bootstrap.
class PearMusicBootstrapErrorApp extends StatefulWidget {
  final Object error;
  final StackTrace stackTrace;
  final Future<void> Function() onRetry;

  const PearMusicBootstrapErrorApp({
    super.key,
    required this.error,
    required this.stackTrace,
    required this.onRetry,
  });

  @override
  State<PearMusicBootstrapErrorApp> createState() => _PearMusicBootstrapErrorAppState();
}

class _PearMusicBootstrapErrorAppState extends State<PearMusicBootstrapErrorApp> {
  bool _isRetrying = false;
  String? _retryError;

  Future<void> _handleRetry() async {
    setState(() {
      _isRetrying = true;
      _retryError = null;
    });
    try {
      await widget.onRetry();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRetrying = false;
          _retryError = e.toString();
        });
      }
    }
  }

  Future<void> _handleResetAndRetry() async {
    setState(() {
      _isRetrying = true;
      _retryError = null;
    });
    try {
      final dir = await getApplicationSupportDirectory();
      final stateFile = File('${dir.path}/peerm_server_state.json');
      if (await stateFile.exists()) {
        await stateFile.delete();
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await widget.onRetry();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRetrying = false;
          _retryError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pear Music Startup Error',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      size: 56,
                      color: Colors.orangeAccent,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Unable to Start Pear Music',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _retryError ?? widget.error.toString(),
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    if (_isRetrying)
                      const CircularProgressIndicator()
                    else ...[
                      FilledButton.icon(
                        onPressed: _handleRetry,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Retry Startup'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _handleResetAndRetry,
                        icon: const Icon(Icons.cleaning_services_rounded),
                        label: const Text('Reset Cached State & Retry'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows controller.messages as SnackBars.
class _MessagesListener extends StatefulWidget {
  final Widget child;
  const _MessagesListener({required this.child});

  @override
  State<_MessagesListener> createState() => _MessagesListenerState();
}

class _MessagesListenerState extends State<_MessagesListener> {
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    final controller = context.read<AppController>();
    _sub = controller.messages.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
