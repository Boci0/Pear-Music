import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/screens/home_screen.dart';
import 'package:peerm_app/screens/home_shell.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/player_theme.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/player_bar.dart';
import 'package:peerm_app/widgets/wide_rail.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(int i) => Song(
  id: 's$i',
  title: 'Track $i',
  fileName: 's$i.mp3',
  size: 1024,
  checksum: 'chk_$i',
  addedAt: DateTime(2026, 1, 1),
);

/// Guards the floating phone navigation: a capsule whose selected tab is a
/// pill with its icon and name, the others icon only; the pill fades and
/// never stretches or slides; lists and snackbars stay clear of it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return Directory.systemTemp.path;
    });
  });

  Future<Widget> buildShell({int songs = 0, bool playing = false}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final list = [for (var i = 0; i < songs; i++) _song(i)];
    library.setSongsForTesting(list);
    final history = HistoryService(prefs);
    final player = PlayerService(library, identity: identity, history: history);
    if (playing) {
      player.updateQueue(list);
      player.currentSong = list.first;
    }
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
      // what a phone shows.
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

  const labels = ['Home', 'Explore', 'Library'];
  Finder tab(String label) => find.byKey(ValueKey('nav_tab_$label'));

  for (final width in [320.0, 360.0, 430.0]) {
    testWidgets(
        'only the selected tab shows its name, in its own slot, at ${width.toInt()}dp',
        (tester) async {
      await useSize(tester, Size(width, 800));
      await tester.pumpWidget(await buildShell());
      await tester.pumpAndSettle();

      final bar = find.byKey(const ValueKey('nav_bar'));
      final barRect = tester.getRect(bar);
      final centres = [for (final l in labels) tester.getCenter(tab(l)).dx];

      for (var i = 0; i < labels.length; i++) {
        await tester.tap(tab(labels[i]));
        await tester.pumpAndSettle();
        for (final other in labels) {
          final name =
              find.descendant(of: tab(other), matching: find.text(other));
          expect(name, other == labels[i] ? findsOneWidget : findsNothing,
              reason: '${labels[i]} selected at ${width}dp: $other');
          expect(find.byTooltip(other), findsOneWidget);
        }
        final pill =
            tester.getRect(find.byKey(const ValueKey('nav_indicator')));
        expect(pill.center.dx, closeTo(centres[i], 1.0));
        if (i > 0) {
          expect(pill.left, greaterThan((centres[i - 1] + centres[i]) / 2));
        }
        if (i < labels.length - 1) {
          expect(pill.right, lessThan((centres[i] + centres[i + 1]) / 2));
        }
        expect(pill.left, greaterThanOrEqualTo(barRect.left));
        expect(pill.right, lessThanOrEqualTo(barRect.right));
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('the capsule floats above the bottom edge with rounded ends',
      (tester) async {
    await useSize(tester, const Size(430, 920));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.byKey(const ValueKey('nav_bar')));
    expect(bar.bottom, lessThan(920));
    expect(bar.left, greaterThan(0));
    expect(bar.right, lessThan(430));
  });

  /// Taps [to] after settling on [from] and checks every frame: the pill
  /// keeps one size and height and only moves toward [to], never past it.
  Future<void> expectSlide(WidgetTester tester, Finder indicator,
      Finder from, Finder to, {required bool vertical}) async {
    await tester.tap(from);
    await tester.pumpAndSettle();
    final start = tester.getRect(indicator);
    await tester.tap(to);
    await tester.pumpAndSettle();
    final end = tester.getRect(indicator);
    await tester.tap(from);
    await tester.pumpAndSettle();

    double pos(Rect r) => vertical ? r.top : r.left;
    await tester.tap(to);
    var last = pos(start);
    var travelled = false;
    for (var f = 0; f < 25; f++) {
      await tester.pump(const Duration(milliseconds: 16));
      final r = tester.getRect(indicator);
      // Positions are lerped in doubles, so allow a hair of rounding.
      expect(r.width, closeTo(start.width, 0.01), reason: 'frame $f: no stretch');
      expect(r.height, closeTo(start.height, 0.01), reason: 'frame $f: no squash');
      if (vertical) {
        expect(r.left, closeTo(start.left, 0.01), reason: 'frame $f');
      } else {
        expect(r.top, closeTo(start.top, 0.01), reason: 'frame $f');
      }
      final p = pos(r);
      final forward = pos(end) > pos(start);
      expect(forward ? p >= last - 0.01 : p <= last + 0.01, isTrue,
          reason: 'frame $f: moves one way only');
      expect(forward ? p <= pos(end) + 0.01 : p >= pos(end) - 0.01, isTrue,
          reason: 'frame $f: no overshoot');
      if (p != pos(start) && p != pos(end)) travelled = true;
      last = p;
    }
    expect(travelled, isTrue, reason: 'it slides rather than jumping');
    await tester.pumpAndSettle();
    expect(tester.getRect(indicator), end);
  }

  testWidgets('the pill slides to the tapped tab at one fixed size',
      (tester) async {
    await useSize(tester, const Size(360, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();
    final indicator = find.byKey(const ValueKey('nav_indicator'));
    await expectSlide(tester, indicator, tab('Home'), tab('Library'),
        vertical: false);
    await expectSlide(tester, indicator, tab('Library'), tab('Explore'),
        vertical: false);
  });

  testWidgets('the icon glides aside and the name comes in beside it',
      (tester) async {
    await useSize(tester, const Size(360, 800));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    double iconX(String label, IconData icon) => tester
        .getCenter(find.descendant(of: tab(label), matching: find.byIcon(icon)))
        .dx;
    double nameOpacity(String label) {
      final text = find.descendant(of: tab(label), matching: find.text(label));
      if (text.evaluate().isEmpty) return 0;
      return tester
          .widgetList<Opacity>(
            find.ancestor(of: text, matching: find.byType(Opacity)),
          )
          .fold(1.0, (o, w) => o * w.opacity);
    }

    final centre = tester.getCenter(tab('Library')).dx;
    expect(iconX('Library', Icons.library_music_rounded), closeTo(centre, 1));

    await tester.tap(tab('Library'));
    await tester.pump();
    var lastLib = iconX('Library', Icons.library_music_rounded);
    var lastHome = iconX('Home', Icons.home_rounded);
    var lastOpacity = 0.0;
    final steps = <double>[];
    for (var f = 0; f < 20; f++) {
      await tester.pump(const Duration(milliseconds: 16));
      final lib = iconX('Library', Icons.library_music_rounded);
      final home = iconX('Home', Icons.home_rounded);
      final opacity = nameOpacity('Library');
      expect(lib, lessThanOrEqualTo(lastLib + 0.01),
          reason: 'frame $f: Library icon moves left only');
      expect(home, greaterThanOrEqualTo(lastHome - 0.01),
          reason: 'frame $f: Home icon moves back to centre only');
      expect(opacity, greaterThanOrEqualTo(lastOpacity),
          reason: 'frame $f: the name only grows in');
      steps.add(lastLib - lib);
      lastLib = lib;
      lastHome = home;
      lastOpacity = opacity;
    }
    await tester.pumpAndSettle();
    final end = iconX('Library', Icons.library_music_rounded);
    final total = centre - end;
    expect(total, greaterThan(10), reason: 'the icon makes room for the name');
    // A glide, not a jump: no single frame covers most of the way.
    for (final step in steps) {
      expect(step, lessThan(total * 0.4));
    }
    expect(nameOpacity('Library'), 1);
    expect(find.descendant(of: tab('Home'), matching: find.text('Home')),
        findsNothing);
    expect(iconX('Home', Icons.home_rounded),
        closeTo(tester.getCenter(tab('Home')).dx, 1));
  });

  testWidgets('the sideways rail pill slides the same way', (tester) async {
    await useSize(tester, const Size(844, 390));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();
    final rail = find.byKey(const ValueKey('landscape_rail'));
    Finder item(String l) => find.descendant(of: rail, matching: find.text(l));
    final indicator = find.byKey(const ValueKey('rail_indicator'));
    await expectSlide(tester, indicator, item('Home'), item('Library'),
        vertical: true);
    final icon = tester.getCenter(find.descendant(
        of: rail, matching: find.byIcon(Icons.library_music_rounded)));
    expect(tester.getCenter(indicator).dy, closeTo(icon.dy, 1));
    expect(tester.getCenter(indicator).dx, closeTo(icon.dx, 1));
  });

  testWidgets('touch interaction does not leave hover highlight stuck',
      (tester) async {
    await useSize(tester, const Size(360, 720));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();

    final touchGesture = await tester.startGesture(
      tester.getCenter(tab('Explore')),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await touchGesture.up();
    await tester.pumpAndSettle();

    final bar = find.byKey(const ValueKey('nav_bar'));
    for (final c in tester.widgetList<AnimatedContainer>(
      find.descendant(of: bar, matching: find.byType(AnimatedContainer)),
    )) {
      expect(
        (c.decoration as BoxDecoration?)?.color,
        isNot(equals(Colors.white.withValues(alpha: 0.06))),
      );
    }
  });

  testWidgets('Library scrolls clear of the floating bar and mini player',
      (tester) async {
    await useSize(tester, const Size(430, 920));
    await tester.pumpWidget(await buildShell(songs: 40, playing: true));
    await tester.pumpAndSettle();
    await tester.tap(tab('Library'));
    await tester.pumpAndSettle();

    final dockTop = tester.getRect(find.byType(PlayerBar)).top;
    expect(dockTop, lessThan(tester.getRect(find.byKey(const ValueKey('nav_bar'))).top));
    await tester.drag(
      find.descendant(
        of: find.byType(HomeScreen),
        matching: find.byType(Scrollable),
      ).first,
      const Offset(0, -30000),
    );
    await tester.pumpAndSettle();

    final rows = find.descendant(
      of: find.byType(HomeScreen),
      matching: find.textContaining('Track '),
    );
    expect(rows, findsWidgets);
    final maxBottom = [
      for (var i = 0; i < rows.evaluate().length; i++)
        tester.getRect(rows.at(i)).bottom,
    ].reduce((a, b) => a > b ? a : b);
    expect(maxBottom, lessThanOrEqualTo(dockTop),
        reason: 'the last row ends above the mini player');

    final fab = tester.getRect(find.byKey(const ValueKey('add_music')));
    expect(fab.bottom, lessThanOrEqualTo(dockTop));
  });

  testWidgets('a snackbar shows above the floating bar', (tester) async {
    await useSize(tester, const Size(430, 920));
    await tester.pumpWidget(await buildShell());
    await tester.pumpAndSettle();
    ScaffoldMessenger.of(tester.element(find.byType(HomeShell))).showSnackBar(
      const SnackBar(
        content: Text('Saved'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.byKey(const ValueKey('nav_bar')));
    expect(tester.getRect(find.byType(SnackBar)).bottom,
        lessThanOrEqualTo(bar.top));
  });

  for (final (size, playing) in const [
    (Size(320, 700), true),
    (Size(430, 920), false),
    (Size(430, 920), true),
    (Size(920, 430), true),
    (Size(1440, 900), true),
  ]) {
    testWidgets('no overflow at $size, playing: $playing', (tester) async {
      await useSize(tester, size);
      await tester.pumpWidget(await buildShell(songs: 3, playing: playing));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (size.width >= 900 && size.height >= 600) {
        final rail = find.byKey(const ValueKey('wide_rail'));
        for (final l in ['Home', 'Explore', 'Library', 'History', 'Playlists',
            'Settings']) {
          expect(find.descendant(of: rail, matching: find.text(l)),
              findsOneWidget);
          await tester.tap(find.descendant(of: rail, matching: find.text(l)));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: l);
        }
        expect(find.byType(WideRail), findsOneWidget);
      } else if (size.height < 500) {
        final rail = find.byKey(const ValueKey('landscape_rail'));
        for (final l in labels) {
          await tester.tap(find.descendant(of: rail, matching: find.text(l)));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: l);
        }
      } else {
        for (final l in labels) {
          await tester.tap(tab(l));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: l);
        }
      }
    });
  }
}
