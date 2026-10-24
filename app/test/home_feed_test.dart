import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/screens/history_screen.dart';
import 'package:peerm_app/screens/home_feed_screen.dart';
import 'package:peerm_app/screens/home_screen.dart';
import 'package:peerm_app/screens/home_shell.dart';
import 'package:peerm_app/screens/settings_screen.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/player_theme.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/wide_rail.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// With New design on, a phone-shaped window opens on Home and its bar holds
/// Home, Explore and Library; with it off the five classic tabs stay.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
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
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: controller),
        ChangeNotifierProvider<PlayerService>.value(value: player),
        ChangeNotifierProvider<IdentityService>.value(value: identity),
        ChangeNotifierProvider<LibraryService>.value(value: library),
        ChangeNotifierProvider<HistoryService>.value(value: history),
        ChangeNotifierProvider<PlayerTheme>.value(value: PlayerTheme(player)),
      ],
      child: const MaterialApp(home: HomeShell()),
    );
  }

  Future<void> useSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// A tab on the phone bar, by name (only the selected one shows it).
  Finder barLabel(String text) => find.byKey(ValueKey('nav_tab_$text'));

  for (final size in const [Size(360, 720), Size(430, 920)]) {
    testWidgets('opens on Home with three tabs at $size', (tester) async {
      await useSize(tester, size);
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();

      expect(find.byType(HomeFeedScreen), findsOneWidget);
      for (final label in ['Home', 'Explore', 'Library']) {
        expect(barLabel(label), findsOneWidget);
      }
      for (final label in ['Playlists', 'History', 'Settings']) {
        expect(barLabel(label), findsNothing);
      }
      expect(find.text('LIKED'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'History opens from Home, lights Library, and back returns Home',
    (tester) async {
      await useSize(tester, const Size(412, 820));
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();

      final indicator = find.byKey(const ValueKey('nav_indicator'));
      final homeX = tester.getRect(indicator).center.dx;

      await tester.tap(find.byKey(const ValueKey('home_history')));
      await tester.pumpAndSettle();
      final historyX = tester.getRect(indicator).center.dx;
      expect(historyX, closeTo(tester.getCenter(barLabel('Library')).dx, 1));
      expect(historyX, greaterThan(homeX));

      await tester.tap(barLabel('Home'));
      await tester.pumpAndSettle();
      expect(tester.getRect(indicator).center.dx, closeTo(homeX, 1));
    },
  );

  testWidgets('Settings button opens Settings and lights Home', (tester) async {
    await useSize(tester, const Size(412, 820));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    final indicator = find.byKey(const ValueKey('nav_indicator'));
    final homeX = tester.getRect(indicator).center.dx;
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeFeedScreen), findsNothing);
    expect(tester.getRect(indicator).center.dx, closeTo(homeX, 1));
  });

  testWidgets('a wide window opens on Home in the wide rail', (tester) async {
    await useSize(tester, const Size(1440, 900));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();
    expect(find.byType(HomeFeedScreen), findsOneWidget);
    expect(find.byType(WideRail), findsOneWidget);
    expect(find.byKey(const ValueKey('nav_bar')), findsNothing);
  });

  testWidgets('asking for Home in a wide window shows Home', (tester) async {
    await useSize(tester, const Size(1440, 900));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();
    HomeShell.requestTab(4);
    await tester.pumpAndSettle();
    HomeShell.requestTab(5);
    await tester.pumpAndSettle();
    expect(find.byType(HomeFeedScreen), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets('empty History goes to Library and lights it', (tester) async {
    await useSize(tester, const Size(412, 820));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('home_history')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GO TO LIBRARY'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(HistoryScreen), findsNothing);
    final indicator = find.byKey(const ValueKey('nav_indicator'));
    expect(
      tester.getRect(indicator).center.dx,
      closeTo(tester.getCenter(barLabel('Library')).dx, 1),
    );
  });

  testWidgets('Library Add music sits above the dock', (tester) async {
    await useSize(tester, const Size(430, 920));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();
    await tester.tap(barLabel('Library'));
    await tester.pumpAndSettle();
    final fab = tester.getRect(find.byKey(const ValueKey('add_music')));
    final bar = tester.getRect(find.byKey(const ValueKey('nav_bar')));
    expect(fab.bottom, lessThanOrEqualTo(bar.top), reason: '$fab vs $bar');
  });

  testWidgets('Library Add music hides while the keyboard is up', (
    tester,
  ) async {
    await useSize(tester, const Size(430, 920));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();
    await tester.tap(barLabel('Library'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add_music')), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add_music')), findsNothing);
  });
}
