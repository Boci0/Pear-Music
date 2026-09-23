import 'dart:io';
import 'dart:ui';

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
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guards the navigation indicator geometry. The indicator used to be sized
/// from the widest label, which made it hug "Playlists" and read as a skinny
/// capsule at five tabs; it is now a fixed capsule behind the icon, with the
/// label below it. These are the numbers that keep it that way.
const Size _indicatorSize = Size(48, 30);

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

  testWidgets('selected indicator is a fixed capsule centred on the tab icon',
      (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    final bar = find.byKey(const ValueKey('nav_bar'));
    final indicator = find.byKey(const ValueKey('nav_indicator'));
    expect(tester.getSize(indicator).width, closeTo(_indicatorSize.width, 0.1));
    expect(tester.getSize(indicator).height, closeTo(_indicatorSize.height, 0.1));

    Rect rectOf(Finder f) => tester.getRect(f);
    Finder navIcon(IconData icon) =>
        find.descendant(of: bar, matching: find.byIcon(icon));

    final libraryIndicator = rectOf(indicator);
    final libraryIcon = rectOf(navIcon(Icons.library_music_rounded));
    expect(
      libraryIndicator.center.dx,
      closeTo(libraryIcon.center.dx, 0.5),
      reason: 'indicator is centred on its icon',
    );
    expect(
      libraryIndicator.center.dy,
      closeTo(libraryIcon.center.dy, 0.5),
      reason: 'icon sits inside the indicator, not beside it',
    );

    // Switching tabs moves the same capsule onto the new icon.
    await tester.tap(find.descendant(of: bar, matching: find.text('Playlists')));
    await tester.pumpAndSettle();
    final playlistsIndicator = rectOf(indicator);
    final playlistsIcon = rectOf(navIcon(Icons.queue_music_rounded));
    expect(playlistsIndicator.size.width, closeTo(_indicatorSize.width, 0.1));
    expect(playlistsIndicator.size.height, closeTo(_indicatorSize.height, 0.1));
    expect(
      playlistsIndicator.center.dx,
      closeTo(playlistsIcon.center.dx, 0.5),
    );
    expect(
      playlistsIndicator.center.dx,
      greaterThan(libraryIndicator.center.dx),
    );
  });

  testWidgets('touch interaction does not leave hover highlight stuck',
      (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    final bar = find.byKey(const ValueKey('nav_bar'));
    final playlistsItem =
        find.descendant(of: bar, matching: find.text('Playlists'));

    // Dispatch a touch event (pointer kind = touch)
    final touchGesture = await tester.startGesture(
      tester.getCenter(playlistsItem),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await touchGesture.up();
    await tester.pumpAndSettle();

    // Verify AnimatedContainers do not have white hover background
    final animatedContainers = tester.widgetList<AnimatedContainer>(
      find.descendant(of: bar, matching: find.byType(AnimatedContainer)),
    );
    for (final container in animatedContainers) {
      final decoration = container.decoration as BoxDecoration?;
      if (decoration != null && decoration.color != null) {
        expect(
          decoration.color,
          isNot(equals(Colors.white.withValues(alpha: 0.08))),
          reason: 'Hover highlight should not be visible after touch interaction',
        );
      }
    }
  });
}
