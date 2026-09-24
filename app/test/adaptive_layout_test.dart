import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/screens/home_shell.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/player_theme.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/player_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guards the adaptive shell: below 900 logical px the phone shell with the
/// bottom navigation bar is used; at 900 px and above the desktop shell with
/// the side rail takes over.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return Directory.systemTemp.path;
    });
  });

  Future<Widget> buildShell() async {
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
    final playerTheme = PlayerTheme(player);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        ChangeNotifierProvider<PlayerService>.value(value: player),
        ChangeNotifierProvider<IdentityService>.value(value: identity),
        ChangeNotifierProvider<LibraryService>.value(value: library),
        ChangeNotifierProvider<HistoryService>.value(value: history),
        ChangeNotifierProvider<PlayerTheme>.value(value: playerTheme),
      ],
      child: const MaterialApp(home: HomeShell()),
    );
  }

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets('wide windows use the side rail and hide the bottom nav',
      (tester) async {
    setViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('side_rail')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav_bar')), findsNothing);
    expect(find.byType(PlayerBar), findsOneWidget);
  });

  testWidgets('phone widths keep the bottom navigation shell',
      (tester) async {
    setViewport(tester, const Size(360, 720));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('side_rail')), findsNothing);
    expect(find.byKey(const ValueKey('nav_bar')), findsOneWidget);
  });

  testWidgets('tapping a rail item switches the shell tab', (tester) async {
    setViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    final rail = find.byKey(const ValueKey('side_rail'));
    await tester.tap(
      find.descendant(of: rail, matching: find.text('Playlists')),
    );
    await tester.pumpAndSettle();

    final shellStack =
        tester.widget<IndexedStack>(find.byType(IndexedStack).first);
    expect(shellStack.index, 1);
  });
}
