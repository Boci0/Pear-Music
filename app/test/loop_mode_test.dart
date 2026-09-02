import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/pear_audio_handler.dart';
import 'package:peerm_app/services/player_service.dart';

/// Locks in the loop/shuffle behaviour the user asked for: the repeat button
/// cycles no-loop -> whole-album -> one-song -> no-loop, and shuffle toggles.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryService library;
  late PearAudioHandler handler;
  late PlayerService player;

  setUp(() {
    library = LibraryService();
    handler = PearAudioHandler();
    player = PlayerService(library, audioHandler: handler);
  });

  test('toggleLoop cycles off -> all -> one -> off', () {
    expect(player.loopMode, LoopSetting.off);
    player.toggleLoop();
    expect(player.loopMode, LoopSetting.all, reason: 'first tap = whole album');
    player.toggleLoop();
    expect(player.loopMode, LoopSetting.one, reason: 'second tap = one song');
    player.toggleLoop();
    expect(player.loopMode, LoopSetting.off, reason: 'third tap = no loop');
  });

  test('toggleShuffle toggles on/off', () {
    expect(player.shuffle, isFalse);
    player.toggleShuffle();
    expect(player.shuffle, isTrue);
    player.toggleShuffle();
    expect(player.shuffle, isFalse);
  });

  test('notification customAction routes loop and shuffle correctly', () async {
    await player.init();
    expect(player.loopMode, LoopSetting.off);
    expect(player.shuffle, isFalse);

    await handler.customAction('peerm_repeat');
    expect(player.loopMode, LoopSetting.all);

    await handler.customAction('peerm_repeat');
    expect(player.loopMode, LoopSetting.one);

    await handler.customAction('peerm_repeat');
    expect(player.loopMode, LoopSetting.off);

    await handler.customAction('peerm_shuffle');
    expect(player.shuffle, isTrue);

    await handler.customAction('peerm_shuffle');
    expect(player.shuffle, isFalse);
  });
}
