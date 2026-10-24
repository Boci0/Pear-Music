import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An engine that takes volume changes and plays nothing.
class _SilentPlayer extends AudioPlayer {
  _SilentPlayer() : super(handleAudioSessionActivation: false);

  @override
  Future<void> setVolume(double volume) async {}
}

/// Quitting within the save delay of a volume change used to drop it: the
/// pending save was cancelled on exit, so the value from before (0.0 after a
/// muted test run) came back on the next start.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(SharedPreferences, AppController, PlayerService)> setUp() async {
    SharedPreferences.setMockInitialValues({'peerm_playback_volume': 1.0});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final player = PlayerService(
      library,
      identity: identity,
      player: _SilentPlayer(),
    );
    final controller = AppController(
      identity: identity,
      library: library,
      player: player,
      youtube: YoutubeService(),
    );
    return (prefs, controller, player);
  }

  test('a volume change right before quitting is saved', () async {
    final (prefs, controller, player) = await setUp();
    await player.setVolume(0.0);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(prefs.getDouble('peerm_playback_volume'), 0.0);

    // Restored and quit at once, inside the save delay.
    await player.setVolume(1.0);
    await controller.didRequestAppExit();
    expect(prefs.getDouble('peerm_playback_volume'), 1.0);
  });

  test('flushing with nothing pending changes nothing', () async {
    final (prefs, _, player) = await setUp();
    await player.flushSavedVolume();
    expect(prefs.getDouble('peerm_playback_volume'), 1.0);
  });
}
