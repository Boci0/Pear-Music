import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/player/player_controls.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guards the seek bar time labels: multi-hour tracks keep the hour component
/// instead of collapsing into raw minutes ("182:36").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return Directory.systemTemp.path;
        });
  });

  testWidgets('seek labels keep hours for multi-hour tracks', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final history = HistoryService(prefs);
    final player = PlayerService(library, identity: identity, history: history);
    final controller = AppController(
      identity: identity,
      library: library,
      player: player,
      youtube: YoutubeService(),
      history: history,
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(value: controller),
          ChangeNotifierProvider<PlayerService>.value(value: player),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PlayerSeekBar(
              player: player,
              duration: const Duration(hours: 3, minutes: 3, seconds: 36),
              accent: Colors.purple,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Default view is the remaining time; the elapsed side shows the position.
    expect(find.text('-3:03:36'), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);
  });
}
