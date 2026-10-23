import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/visualizer_feed.dart';
import 'package:peerm_app/services/window_focus.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/widgets/player/mini_visualizer.dart';
import 'package:peerm_app/widgets/player_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppController> mount(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final identity = IdentityService(await SharedPreferences.getInstance());
    final library = LibraryService();
    final player = PlayerService(library);
    final controller = AppController(
      identity: identity,
      library: library,
      player: player,
      youtube: YoutubeService(),
    );
    final song = Song(
      id: 's1',
      title: 'Creep',
      fileName: 's1.mp3',
      size: 1024,
      checksum: 'chk',
      addedAt: DateTime(2026, 1, 1),
    );
    player.updateQueue([song]);
    player.currentSong = song;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: controller),
          ChangeNotifierProvider.value(value: player),
        ],
        child: const MaterialApp(
          home: Scaffold(bottomNavigationBar: PlayerBar()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('the mini player has no bars until they are switched on',
      (tester) async {
    final controller = await mount(tester);
    expect(controller.identity.synthesizerBar, isTrue,
        reason: 'the visualizer itself is on by default');
    expect(find.byType(MiniVisualizer), findsNothing);

    await controller.updateMiniVisualizer(true);
    await tester.pumpAndSettle();
    expect(find.byType(MiniVisualizer), findsOneWidget);

    await controller.updateMiniVisualizer(false);
    await tester.pumpAndSettle();
    expect(find.byType(MiniVisualizer), findsNothing);
  });

  testWidgets('the mini player bars need the visualizer and respect Reduced Effects',
      (tester) async {
    final controller = await mount(tester);
    await controller.updateMiniVisualizer(true);
    await tester.pumpAndSettle();
    expect(find.byType(MiniVisualizer), findsOneWidget);

    await controller.updateSynthesizerBar(false);
    await tester.pumpAndSettle();
    expect(find.byType(MiniVisualizer), findsNothing);

    await controller.updateSynthesizerBar(true);
    await controller.updateReducedEffects(true);
    await tester.pumpAndSettle();
    expect(find.byType(MiniVisualizer), findsNothing);
  });

  testWidgets('a covered mini wave does not keep the feed running unfocused',
      (tester) async {
    final player = PlayerService(LibraryService());
    final feed = VisualizerFeed.instance;
    addTearDown(() => WindowFocus.focused.value = true);
    Widget wave(bool onScreen) => TickerMode(
          enabled: onScreen,
          child: MiniVisualizer(player: player, color: Colors.white),
        );

    await tester.pumpWidget(wave(true));
    WindowFocus.focused.value = false;
    expect(feed.renderActive, isTrue, reason: 'on screen, watched from the side');

    // Under the full player: the artwork visualizer must pause unfocused.
    await tester.pumpWidget(wave(false));
    expect(feed.renderActive, isFalse);

    await tester.pumpWidget(wave(true));
    expect(feed.renderActive, isTrue);

    await tester.pumpWidget(const SizedBox());
    WindowFocus.focused.value = true;
  });
}
