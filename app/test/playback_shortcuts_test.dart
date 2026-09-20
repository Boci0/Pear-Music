import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/widgets/playback_shortcuts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(String id, String title) => Song(
      id: id,
      title: title,
      fileName: '$id.mp3',
      size: 100,
      checksum: 'chk_$id',
      addedAt: DateTime(2026, 1, 1),
    );

/// Builds a player with a four song queue and an already loaded current song.
/// The song is set directly so the tests never touch the real load path.
Future<PlayerService> _loadedPlayer({int atIndex = 0}) async {
  SharedPreferences.setMockInitialValues({});
  final player = PlayerService(LibraryService());
  player.updateQueue(
    [for (var i = 1; i <= 4; i++) _song('s$i', 'Song $i')],
    sourceId: 'test',
    sourceTitle: 'Test',
  );
  player.currentSong = player.queue[atIndex];
  return player;
}

/// Mirrors the production wiring: the shortcuts layer wraps the navigator, so
/// key events bubbling up from any route reach it.
Widget _wrap(PlayerService player, {required Widget home}) {
  return ChangeNotifierProvider<PlayerService>.value(
    value: player,
    child: MaterialApp(
      builder: (context, child) =>
          PlaybackShortcuts(child: child ?? const SizedBox.shrink()),
      home: home,
    ),
  );
}

Future<void> _pressCtrlAlt(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

/// Lets a shortcut's async work (the track advance) run far enough for the
/// optimistic current song swap to be observable.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('playback keys are inert while nothing is loaded', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final player = PlayerService(LibraryService());
    await tester.pumpWidget(
      _wrap(player, home: const Scaffold(body: Text('idle'))),
    );

    await _pressCtrlAlt(tester, LogicalKeyboardKey.space);
    await _pressCtrlAlt(tester, LogicalKeyboardKey.keyN);
    await _pressCtrlAlt(tester, LogicalKeyboardKey.keyB);
    await _pressCtrlAlt(tester, LogicalKeyboardKey.keyL);
    await _pressCtrlAlt(tester, LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackNext);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackPrevious);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyEvent(LogicalKeyboardKey.period);
    await tester.pump();

    expect(player.currentSong, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Shift+N skips to the next track', (tester) async {
    final player = await _loadedPlayer();
    await tester.pumpWidget(_wrap(player, home: const Scaffold(body: Text('run'))));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await _settle(tester);

    expect(player.currentSong?.id, 's2');
  });

  testWidgets('the period key skips to the next track', (tester) async {
    final player = await _loadedPlayer();
    await tester.pumpWidget(_wrap(player, home: const Scaffold(body: Text('run'))));

    await tester.sendKeyEvent(LogicalKeyboardKey.period);
    await _settle(tester);

    expect(player.currentSong?.id, 's2');
  });

  testWidgets('the comma key steps back to the previous track', (tester) async {
    final player = await _loadedPlayer(atIndex: 2);
    await tester.pumpWidget(_wrap(player, home: const Scaffold(body: Text('run'))));
    expect(player.currentSong?.id, 's3');

    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await _settle(tester);

    expect(player.currentSong?.id, 's2');
  });

  testWidgets('Ctrl+Alt+N skips to the next track', (tester) async {
    final player = await _loadedPlayer();
    await tester.pumpWidget(_wrap(player, home: const Scaffold(body: Text('run'))));

    await _pressCtrlAlt(tester, LogicalKeyboardKey.keyN);
    await _settle(tester);

    expect(player.currentSong?.id, 's2');
  });

  testWidgets('the media next key skips to the next track', (tester) async {
    final player = await _loadedPlayer();
    await tester.pumpWidget(_wrap(player, home: const Scaffold(body: Text('run'))));

    await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackNext);
    await _settle(tester);

    expect(player.currentSong?.id, 's2');
  });

  testWidgets('Ctrl+Alt+B steps back to the previous track', (tester) async {
    final player = await _loadedPlayer(atIndex: 2);
    await tester.pumpWidget(_wrap(player, home: const Scaffold(body: Text('run'))));
    expect(player.currentSong?.id, 's3');

    await _pressCtrlAlt(tester, LogicalKeyboardKey.keyB);
    await _settle(tester);

    expect(player.currentSong?.id, 's2');
  });

  testWidgets('typing in a search field never triggers playback', (
    tester,
  ) async {
    final player = await _loadedPlayer();
    await tester.pumpWidget(
      _wrap(player, home: const Scaffold(body: TextField())),
    );

    // Every single key shortcut must stay inert while the field owns the
    // keyboard, otherwise typing a word like "lkj" would skip tracks.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'klj space');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyEvent(LogicalKeyboardKey.period);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await _settle(tester);

    expect(player.currentSong?.id, 's1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('every playback action has a bound key', (tester) async {
    final player = await _loadedPlayer();
    await tester.pumpWidget(_wrap(player, home: const Scaffold(body: Text('x'))));

    final shortcuts = tester
        .widgetList<Shortcuts>(find.byType(Shortcuts))
        .expand((widget) => widget.shortcuts.keys)
        .whereType<SingleActivator>()
        .toList();

    bool has(LogicalKeyboardKey key, {bool control = false, bool alt = false, bool shift = false}) {
      return shortcuts.any((activator) =>
          activator.trigger == key &&
          activator.control == control &&
          activator.alt == alt &&
          activator.shift == shift);
    }

    // Single key shortcuts (YouTube style).
    expect(has(LogicalKeyboardKey.space), isTrue);
    expect(has(LogicalKeyboardKey.keyK), isTrue);
    expect(has(LogicalKeyboardKey.keyJ), isTrue);
    expect(has(LogicalKeyboardKey.keyL), isTrue);
    expect(has(LogicalKeyboardKey.comma), isTrue);
    expect(has(LogicalKeyboardKey.period), isTrue);
    expect(has(LogicalKeyboardKey.keyN, shift: true), isTrue);
    expect(has(LogicalKeyboardKey.keyP, shift: true), isTrue);

    expect(has(LogicalKeyboardKey.space, control: true, alt: true), isTrue);
    expect(has(LogicalKeyboardKey.keyN, control: true, alt: true), isTrue);
    expect(has(LogicalKeyboardKey.keyB, control: true, alt: true), isTrue);
    expect(has(LogicalKeyboardKey.keyJ, control: true, alt: true), isTrue);
    expect(has(LogicalKeyboardKey.keyL, control: true, alt: true), isTrue);
    expect(has(LogicalKeyboardKey.mediaPlayPause), isTrue);
    expect(has(LogicalKeyboardKey.mediaTrackNext), isTrue);
    expect(has(LogicalKeyboardKey.mediaTrackPrevious), isTrue);
  });
}
