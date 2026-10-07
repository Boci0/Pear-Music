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

/// Guards the shape of the selected-tab pill. It wraps the icon and the label,
/// and it is sized from the label so the letters never look squeezed: at five
/// tabs the slots are narrow, and an earlier pill that filled its slot left only
/// a few pixels around "Playlists".
const double _minLabelPadding = 9;

/// The pill is meant to be clearly wider than tall; a squarer one reads as a
/// blob and a flatter one as a stripe.
const double _minAspect = 1.35;
const double _maxAspect = 2.0;
const double _minVerticalPadding = 4;

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
      // Flutter tests draw every glyph as a full-em square (the Ahem font), twice
      // as wide as a real label. Halving the text scale gives widths close to
      // what a phone shows, so the room around the letters is measured fairly.
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(0.5)),
          child: child!,
        ),
        home: const HomeShell(),
      ),
    );
  }

  Future<void> useSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  const tabs = <(String, IconData)>[
    ('Library', Icons.library_music_rounded),
    ('Playlists', Icons.queue_music_rounded),
    ('Explore', Icons.explore_rounded),
    ('History', Icons.history_rounded),
    ('Settings', Icons.settings_rounded),
  ];

  for (final width in [320.0, 360.0, 412.0]) {
    testWidgets(
        'the selected pill wraps the icon and the label with room to spare at ${width.toInt()}dp',
        (tester) async {
      await useSize(tester, Size(width, 720));
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();

      final bar = find.byKey(const ValueKey('nav_bar'));
      final indicator = find.byKey(const ValueKey('nav_indicator'));

      for (final (label, icon) in tabs) {
        await tester.tap(find.descendant(of: bar, matching: find.text(label)));
        await tester.pumpAndSettle();

        final pill = tester.getRect(indicator);
        final labelRect =
            tester.getRect(find.descendant(of: bar, matching: find.text(label)));
        final iconRect =
            tester.getRect(find.descendant(of: bar, matching: find.byIcon(icon)));
        final barRect = tester.getRect(bar);

        expect(pill.left - labelRect.left, lessThanOrEqualTo(-_minLabelPadding),
            reason: '$label at ${width}dp: room left of the label');
        expect(pill.right - labelRect.right, greaterThanOrEqualTo(_minLabelPadding),
            reason: '$label at ${width}dp: room right of the label');
        expect(
          (labelRect.left - pill.left) - (pill.right - labelRect.right),
          closeTo(0, 1.0),
          reason: '$label at ${width}dp: the label sits in the middle of the pill',
        );
        expect(iconRect.top - pill.top, greaterThanOrEqualTo(_minVerticalPadding),
            reason: '$label at ${width}dp: room above the icon');
        expect(pill.bottom - labelRect.bottom,
            greaterThanOrEqualTo(_minVerticalPadding),
            reason: '$label at ${width}dp: room below the label');
        expect(pill.center.dx, closeTo(iconRect.center.dx, 1.0),
            reason: '$label at ${width}dp: pill is centred on the tab');
        expect(pill.width / pill.height, inInclusiveRange(_minAspect, _maxAspect),
            reason: '$label at ${width}dp: pill proportions (${pill.width} x ${pill.height})');
        expect(pill.left, greaterThanOrEqualTo(barRect.left),
            reason: '$label at ${width}dp: pill stays inside the bar');
        expect(pill.right, lessThanOrEqualTo(barRect.right));
      }
    });
  }

  testWidgets('the side rail pill wraps the icon and the label with room to spare',
      (tester) async {
    await useSize(tester, const Size(1280, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    final rail = find.byKey(const ValueKey('side_rail'));
    final indicator = find.byKey(const ValueKey('side_rail_indicator'));

    for (final (label, icon) in tabs) {
      await tester.tap(find.descendant(of: rail, matching: find.text(label)));
      await tester.pumpAndSettle();

      final pill = tester.getRect(indicator);
      final labelRect =
          tester.getRect(find.descendant(of: rail, matching: find.text(label)));
      final iconRect =
          tester.getRect(find.descendant(of: rail, matching: find.byIcon(icon)));
      final railRect = tester.getRect(rail);

      expect(labelRect.left - pill.left, greaterThanOrEqualTo(_minLabelPadding),
          reason: '$label: room left of the label');
      expect(pill.right - labelRect.right, greaterThanOrEqualTo(_minLabelPadding),
          reason: '$label: room right of the label');
      expect(iconRect.top - pill.top, greaterThanOrEqualTo(_minVerticalPadding),
          reason: '$label: room above the icon');
      expect(pill.bottom - labelRect.bottom,
          greaterThanOrEqualTo(_minVerticalPadding),
          reason: '$label: room below the label');
      expect(pill.width / pill.height, inInclusiveRange(_minAspect, _maxAspect),
          reason: '$label: pill proportions (${pill.width} x ${pill.height})');
      expect(pill.left, greaterThan(railRect.left),
          reason: '$label: pill stays inside the rail');
      expect(pill.right, lessThan(railRect.right));
      expect(pill.center.dx, closeTo(iconRect.center.dx, 1.0));
    }
  });

  testWidgets('the pill glides to the tapped tab and resizes to its label',
      (tester) async {
    await useSize(tester, const Size(360, 720));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    final bar = find.byKey(const ValueKey('nav_bar'));
    final indicator = find.byKey(const ValueKey('nav_indicator'));
    final library = tester.getRect(indicator);

    await tester.tap(find.descendant(of: bar, matching: find.text('Playlists')));
    await tester.pumpAndSettle();
    final playlists = tester.getRect(indicator);

    expect(playlists.center.dx, greaterThan(library.center.dx));
    expect(playlists.width, greaterThan(library.width),
        reason: '"Playlists" is the longer label, so its pill is wider');
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
