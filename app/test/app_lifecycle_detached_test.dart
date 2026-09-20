import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android stays alive when the activity is destroyed with the back gesture',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final library = LibraryService();
        final controller = AppController(
          identity: IdentityService(prefs),
          library: library,
          player: PlayerService(library),
          youtube: YoutubeService(),
        );

        var notifications = 0;
        controller.addListener(() => notifications++);

        // The back gesture destroys the activity, but the cached engine and
        // this isolate survive behind the media service, so the controller
        // must NOT tear itself down: the user can reopen straight into it.
        controller.didChangeAppLifecycleState(AppLifecycleState.detached);
        await tester.pump();

        controller.notifyListeners();
        expect(
          notifications,
          1,
          reason: 'controller must keep notifying after detached on Android',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
