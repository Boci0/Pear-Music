import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/screens/settings_screen.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/theme/glass.dart';
import 'package:peerm_app/widgets/pear_app_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every setting's title, in screen order.
const _settings = [
  'Master Volume',
  'Loudness Normalization',
  'Crossfade',
  'Endless Play',
  'Auto-Reroll Seed',
  'Fast audio engine',
  'Backup audio engine',
  'Visualizer',
  'Wave on the mini player',
  'Video quality',
  'Reduced Effects',
  'Expanded Search Scope',
  'Clear streaming cache',
  'Check for updates',
  'About Pear Music',
];

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final identity = IdentityService(prefs);
  final library = LibraryService();
  final player = PlayerService(library, identity: identity);
  final controller = AppController(
    identity: identity,
    library: library,
    player: player,
    youtube: YoutubeService(),
  );
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: controller),
        ChangeNotifierProvider.value(value: player),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectEverySettingInOrder(WidgetTester tester) {
  var lastY = -1.0;
  for (final title in _settings) {
    final found = find.text(title);
    expect(found, findsOneWidget, reason: '$title is still on the screen');
    final y = tester.getTopLeft(found).dy;
    expect(y, greaterThan(lastY), reason: '$title keeps its place');
    lastY = y;
  }
}

/// A numbered section heading ("02   Performance") naming [name].
Finder _sectionTitle(String name) => find.byWidgetPredicate((w) {
  if (w is! RichText) return false;
  final text = w.text.toPlainText();
  return RegExp(r'^\d\d   ').hasMatch(text) && text.contains(name);
});

bool _marked(WidgetTester tester, String name) {
  final box = tester.widget<AnimatedContainer>(
    find.ancestor(
      of: find.text(name),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return (box.decoration as BoxDecoration?)?.border != null;
}

void main() {
  for (final (label, size) in [
    ('phone', const Size(430, 920)),
    ('wide', const Size(1440, 900)),
  ]) {
    testWidgets('the $label screen keeps every setting in order', (
      tester,
    ) async {
      await _pump(tester, size: size);
      expect(find.byType(PearTabTitle), findsNothing);
      expect(find.text('SETTINGS'), findsOneWidget);
      expect(find.text('Preferences'), findsOneWidget);
      _expectEverySettingInOrder(tester);
      // The New design switch is gone; Visualizer leads 02 Performance.
      final performance = _sectionTitle('02   Performance');
      expect(performance, findsOneWidget);
      expect(find.text('New design'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Visualizer')).dy,
        greaterThan(tester.getTopLeft(performance).dy),
      );
      // Panels stop at about 760 px.
      for (final panel in find.byType(PearGlass).evaluate()) {
        expect(
          tester.getSize(find.byWidget(panel.widget)).width,
          lessThanOrEqualTo(760),
        );
      }
    });
  }

  testWidgets('phone: no section list', (tester) async {
    await _pump(tester, size: const Size(430, 920));
    expect(find.text('Discovery & Search'), findsNothing);
  });

  testWidgets(
    'wide: the section list scrolls to its section and marks it',
    (tester) async {
      await _pump(tester, size: const Size(1440, 900));
      expect(_marked(tester, 'Audio & Playback'), isTrue);

      await tester.tap(find.text('Discovery & Search'));
      await tester.pumpAndSettle();
      final top = tester.getTopLeft(_sectionTitle('Discovery & Search')).dy;
      // Hosts without the Windows or Android only sections have a shorter list
      // that cannot scroll the section all the way up; it then stops at the end.
      final position = Scrollable.of(
        tester.element(_sectionTitle('Discovery & Search')),
      ).position;
      expect(
        top <= 60 || position.pixels >= position.maxScrollExtent - 1,
        isTrue,
        reason: 'top $top, scrolled ${position.pixels} of ${position.maxScrollExtent}',
      );
      expect(position.pixels, greaterThan(0));
      expect(_marked(tester, 'Discovery & Search'), isTrue);
      expect(_marked(tester, 'Audio & Playback'), isFalse);

      // Scrolling by hand moves the mark too.
      await tester.drag(find.text('Check for updates'), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(_marked(tester, 'About & Updates'), isTrue);
      await tester.drag(find.text('Check for updates'), const Offset(0, 3000));
      await tester.pumpAndSettle();
      expect(_marked(tester, 'Audio & Playback'), isTrue);
    },
  );

  testWidgets(
    'wide: the section in view stands out and a picked one flashes',
    (tester) async {
      await _pump(tester, size: const Size(1440, 900));
      final accent = Theme.of(
        tester.element(find.byType(SettingsScreen)),
      ).colorScheme.primary;
      expect(_titleColor(tester, 'Audio & Playback'), accent);
      expect(_titleColor(tester, 'Discovery & Search'), isNot(accent));
      expect(_edge(tester, 0), accent);
      expect(_edge(tester, 2), Colors.transparent);

      await tester.tap(find.text('Discovery & Search'));
      // The scroll takes 320 ms, then the panel flashes.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_tint(tester, 2), greaterThan(0.12));
      await tester.pumpAndSettle();
      // Settled: the faint tint of the section in view stays.
      expect(_tint(tester, 2), closeTo(0.05, 0.01));
      expect(_tint(tester, 0), 0);
      expect(_titleColor(tester, 'Discovery & Search'), accent);
      expect(_edge(tester, 2), accent);
      expect(_edge(tester, 0), Colors.transparent);
    },
  );

  testWidgets('section headings are larger than the rows', (tester) async {
    await _pump(tester, size: const Size(1440, 900));
    final heading = tester.getSize(_sectionTitle('Audio & Playback')).height;
    final row = tester.getSize(find.text('Crossfade')).height;
    expect(heading, greaterThanOrEqualTo(row));
  });
}

Color? _titleColor(WidgetTester tester, String name) {
  Color? color;
  tester.widget<RichText>(_sectionTitle(name)).text.visitChildren((span) {
    if ((span as TextSpan).text?.contains(name) ?? false) {
      color = span.style?.color;
    }
    return true;
  });
  return color;
}

Color _edge(WidgetTester tester, int i) {
  final box = tester.widget<DecoratedBox>(
    find.byKey(ValueKey('settings_panel_$i')),
  );
  return ((box.decoration as BoxDecoration).border! as Border).left.color;
}

double _tint(WidgetTester tester, int i) =>
    tester.widget<Material>(find.byKey(ValueKey('settings_tint_$i'))).color!.a;

