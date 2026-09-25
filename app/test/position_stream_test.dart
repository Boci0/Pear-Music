import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guards against the position-stream timer leak: just_audio's
/// createPositionStream starts a periodic timer that outlives its listeners,
/// so the player must hand every widget the same shared stream instead of
/// building a new one each time it is read (widgets read it inside build).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return Directory.systemTemp.path;
        });
  });

  test('positionStream is one shared broadcast stream', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final player = PlayerService(
      LibraryService(),
      identity: IdentityService(prefs),
      history: HistoryService(prefs),
    );

    final first = player.positionStream;
    expect(identical(first, player.positionStream), isTrue);
    expect(first.isBroadcast, isTrue);

    // Several widgets can listen at once.
    final a = first.listen((_) {});
    final b = player.positionStream.listen((_) {});
    await a.cancel();
    await b.cancel();
  });
}
