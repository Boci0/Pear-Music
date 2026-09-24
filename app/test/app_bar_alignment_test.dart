import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/screens/explore_screen.dart';
import 'package:peerm_app/screens/history_screen.dart';
import 'package:peerm_app/screens/home_screen.dart';
import 'package:peerm_app/screens/playlists_screen.dart';
import 'package:peerm_app/screens/settings_screen.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/pear_app_bar.dart';
import 'package:peerm_app/widgets/tactile_button.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guards the shared header geometry: every tab must start its pear mark at the
/// same 16px inset and end its action row at the same 8px inset, with 40px
/// action boxes. Mixing Material `IconButton` (48px) with `TactileIconButton`
/// (40px) is what made the Library header drift away from the other tabs.
const double _screenWidth = 400;
const double _startInset = 16;
const double _actionBox = kAppBarActionBox;
const double _endInset = kAppBarActionInset;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return Directory.systemTemp.path;
    });
  });

  void configureViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(_screenWidth, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<Widget> buildScreen(Widget screen) async {
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
      ],
      child: MaterialApp(
        // Same app bar theme the app ships (player_theme.dart).
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: const Color(0xFF0C0C0E),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF0C0C0E),
            scrolledUnderElevation: 0,
            elevation: 0,
            centerTitle: false,
            titleSpacing: 16,
          ),
        ),
        home: screen,
      ),
    );
  }

  for (final entry in <String, Widget>{
    'Library': const HomeScreen(),
    'Playlists': const PlaylistsScreen(),
    'Explore': const ExploreScreen(isActive: false),
    'History': const HistoryScreen(),
    'Settings': const SettingsScreen(),
  }.entries) {
    testWidgets('${entry.key} header uses the shared insets', (tester) async {
      configureViewport(tester);
      await tester.pumpWidget(await buildScreen(entry.value));
      await tester.pumpAndSettle();

      final mark = find.byType(PearMark);
      expect(mark, findsOneWidget, reason: '${entry.key} shows the pear mark');
      expect(
        tester.getTopLeft(mark).dx,
        _startInset,
        reason: '${entry.key} starts its header at the shared 16px inset',
      );

      // Every action in the bar must use the same 40px box and the row must end
      // at the shared 8px inset, whichever widget type the screen picked.
      final actions = find.descendant(
        of: find.byType(AppBar),
        matching: find.byWidgetPredicate(
          (w) => w is TactileIconButton || w is PearMenuButton,
        ),
      );
      if (actions.evaluate().isEmpty) return;

      var rightmost = 0.0;
      for (var i = 0; i < actions.evaluate().length; i++) {
        expect(
          tester.getSize(actions.at(i)).width,
          _actionBox,
          reason: '${entry.key} action $i keeps the shared 40px box',
        );
        final right = tester.getTopRight(actions.at(i)).dx;
        if (right > rightmost) rightmost = right;
      }
      expect(
        rightmost,
        _screenWidth - _endInset,
        reason: '${entry.key} ends its actions at the shared 8px inset',
      );
    });
  }

  testWidgets('Library header stays pinned left while crossfading into search',
      (tester) async {
    configureViewport(tester);
    await tester.pumpWidget(await buildScreen(const HomeScreen()));
    await tester.pumpAndSettle();

    // Entering search swaps the min-width tab title for a full-width search
    // header. Mid-transition both children share the app bar stack, and the
    // default AnimatedSwitcher layout centred the fading title in the wider
    // stack (pear + "Library" drifted to the middle of the bar).
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    final titleDx = tester.getTopLeft(find.text('Library')).dx;
    expect(
      titleDx,
      lessThan(100),
      reason: 'the fading title must stay at the leading edge (resting x is '
          '16 + 28px mark + 8 gap = 52), not drift to the middle of the '
          'search header',
    );

    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
  });
}
