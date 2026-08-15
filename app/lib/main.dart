import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'controllers/app_controller.dart';
import 'screens/home_shell.dart';
import 'services/identity_service.dart';
import 'services/library_service.dart';
import 'services/player_service.dart';
import 'services/player_theme.dart';
import 'services/signaling_server.dart';
import 'services/signaling_service.dart';
import 'services/sync_service.dart';
import 'services/youtube_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Enables the media_kit backend for Windows audio playback.
  JustAudioMediaKit.ensureInitialized();

  // On Android, host the media notification (play/pause + next/previous + lock
  // screen) via just_audio_background. Windows stays on media_kit and gets no
  // notification (it is a desktop app). The manifest already declares the
  // AudioService / MediaButtonReceiver components.
  if (Platform.isAndroid) {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.peerm.peerm_app.channel.audio',
      androidNotificationChannelName: 'Audio playback',
      androidNotificationIcon: 'mipmap/ic_notification',
      // NOT androidNotificationOngoing:true here — combined with
      // androidStopForegroundOnPause:false, audio_service asserts
      // ("!androidNotificationOngoing || androidStopForegroundOnPause") and the
      // DEBUG build crashes to a black screen (assert is stripped in release,
      // so the release APK hid this). The notification still stays visible
      // while paused because the foreground service persists.
      androidStopForegroundOnPause: false,
    );
  }

  // Swallow + log any unhandled async/plugin exception instead of letting it
  // take the app down. This is what caused the black screen during pairing: a
  // flutter_webrtc native data channel threw "Bad state: Cannot add new events
  // after calling close" as an unhandled exception. Sync keeps working over the
  // relay; the error is still recorded in the logs.
  FlutterError.onError = (details) {
    debugPrint('[pearmusic] FlutterError: ${details.exception}');
    // details.toString() includes the relevant error-causing widget, which is
    // how we find RenderFlex overflow locations on this device (screencap is
    // black for Flutter content, so the widget chain is the only clue).
    debugPrint('[pearmusic] ${details.toString()}');
    debugPrint('[pearmusic] ${details.stack}');
  };
  WidgetsBinding.instance.platformDispatcher.onError =
      (Object error, StackTrace stack) {
    debugPrint('[pearmusic] Unhandled exception: $error');
    debugPrint('[pearmusic] $stack');
    return true; // handled — keep the app alive
  };

  final prefs = await SharedPreferences.getInstance();
  final identity = IdentityService(prefs);
  final library = LibraryService();
  final signaling = SignalingService(identity);
  final sync = SyncService(identity: identity, library: library);
  final player = PlayerService(library);
  final youtube = YoutubeService();
  unawaited(YoutubeService.checkDesktopYtDlpUpdate());

  // Embedded signaling server. It is NOT started here — the controller starts
  // it only when this device is the host (the "last online" device), so at any
  // moment exactly one device on the network runs the server. State (pairings/
  // names/secrets) persists in the app support directory.
  final server = SignalingServer(
    port: 8080,
    stateFile: File(
      '${(await getApplicationSupportDirectory()).path}/peerm_server_state.json',
    ),
    onLog: (m) => debugPrint('[server] $m'),
    advertiseName: identity.deviceName,
    advertiseDeviceId: identity.deviceId,
  );

  final controller = AppController(
    identity: identity,
    library: library,
    signaling: signaling,
    sync: sync,
    player: player,
    youtube: youtube,
    server: server,
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
    // Expose the services alongside AppController so widgets can subscribe to
    // the narrowest possible notifier (e.g. TransferList watches SyncService
    // directly instead of AppController, which no longer re-broadcasts the
    // ~100ms transfer ticks — that was the main cause of UI jank).
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        ChangeNotifierProvider<LibraryService>.value(value: controller.library),
        ChangeNotifierProvider<SyncService>.value(value: controller.sync),
        ChangeNotifierProvider<PlayerService>.value(value: controller.player),
        ChangeNotifierProvider<PlayerTheme>.value(value: playerTheme),
      ],
      // The whole app's theme is re-seeded from the current song's artwork
      // colour (dark mode preserved), so the colour follows the music app-wide
      // — not just on the player. AnimatedTheme fades between themes when the
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



/// Shows controller.messages as SnackBars.
class _MessagesListener extends StatefulWidget {
  final Widget child;
  const _MessagesListener({required this.child});

  @override
  State<_MessagesListener> createState() => _MessagesListenerState();
}

class _MessagesListenerState extends State<_MessagesListener> {
  @override
  void initState() {
    super.initState();
    final controller = context.read<AppController>();
    controller.messages.listen((message) {
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
  Widget build(BuildContext context) => widget.child;
}
