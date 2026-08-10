import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/main.dart';
import 'package:peerm_app/models/peer_device.dart';
import 'package:peerm_app/screens/home_shell.dart';
import 'package:peerm_app/screens/pair_screen.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/player_theme.dart';
import 'package:peerm_app/services/signaling_service.dart';
import 'package:peerm_app/services/sync_service.dart';
import 'package:peerm_app/services/youtube_service.dart';

/// An [AppController] whose paired-device list we control directly, so a test
/// can simulate the pairing event and the flood of notifications that follow
/// it (sync handshake, file-transfer progress, presence updates, …).
class _TestController extends AppController {
  _TestController({
    required super.identity,
    required super.library,
    required super.signaling,
    required super.sync,
    required super.player,
    required super.youtube,
  });

  final List<PeerDevice> peers = [];

  @override
  List<PeerDevice> get pairedDevices => List.unmodifiable(peers);

  /// Simulate a successful pairing exactly like the server 'paired' path does.
  void pair(PeerDevice peer) {
    peers.add(peer);
    notifyListeners();
  }
}

Future<_TestController> _buildController() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final identity = IdentityService(prefs);
  final library = LibraryService();
  final signaling = SignalingService(identity);
  final sync = SyncService(identity: identity, library: library);
  final player = PlayerService(library);
  return _TestController(
    identity: identity,
    library: library,
    signaling: signaling,
    sync: sync,
    player: player,
    youtube: YoutubeService(),
  );
}

void main() {
  testWidgets(
      'PairScreen auto-pops exactly once after pairing; the shell is not popped',
      (tester) async {
    final controller = await _buildController();

    await tester.pumpWidget(PearMusicApp(
      controller: controller,
      playerTheme: PlayerTheme(controller.player),
    ));

    // Go to the Devices tab and open the Pair screen.
    await tester.tap(find.text('Devices'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Pair a device'));
    await tester.pumpAndSettle();
    expect(find.byType(PairScreen), findsOneWidget);
    // HomeShell is below the pushed route, so it is offstage while the Pair
    // screen is on top; assert it is still in the tree.
    expect(find.byType(HomeShell, skipOffstage: false), findsOneWidget);

    // Pairing succeeds. Immediately after, the app floods listeners with
    // notifications (manifest sync, binary chunks, presence…). A naive
    // listener would schedule a pop for EVERY notification, and the second
    // pop would remove the HomeShell underneath → black screen.
    controller.pair(
      PeerDevice(deviceId: 'peer-1', deviceName: 'Phone', online: true),
    );
    for (var i = 0; i < 60; i++) {
      controller.notifyListeners();
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // The Pair screen was popped exactly once…
    expect(find.byType(PairScreen), findsNothing);
    // …and the HomeShell is still alive (nothing below it was popped).
    expect(find.byType(HomeShell), findsOneWidget);

    // Sanity: we're back on the Devices tab and the new peer is listed.
    expect(find.text('Paired devices'), findsOneWidget);
    expect(find.text('Phone'), findsOneWidget);
  });

  testWidgets('pumping a second peer later still leaves the shell intact',
      (tester) async {
    final controller = await _buildController();

    await tester.pumpWidget(PearMusicApp(
      controller: controller,
      playerTheme: PlayerTheme(controller.player),
    ));
    await tester.tap(find.text('Devices'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Pair a device'));
    await tester.pumpAndSettle();

    controller.pair(
      PeerDevice(deviceId: 'peer-1', deviceName: 'Phone', online: true),
    );
    // Fire the post-frame callback that performs the actual pop.
    await tester.pumpAndSettle();
    expect(find.byType(PairScreen), findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);
  });
}
