import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<IdentityService> load([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    final identity = IdentityService(await SharedPreferences.getInstance());
    return identity;
  }

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('the visualizer is on by default on desktop', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect((await load()).synthesizerBar, isTrue);
  });

  test('on Android it waits for the switch, which asks for the microphone',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect((await load()).synthesizerBar, isFalse);
  });

  test('the visualizer setting survives a restart, off as well as on', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final identity = await load();
    await identity.setSynthesizerBar(false);

    final prefs = await SharedPreferences.getInstance();
    final reloaded = IdentityService(prefs);
    expect(reloaded.synthesizerBar, isFalse);

    await reloaded.setSynthesizerBar(true);
    final again = IdentityService(prefs);
    expect(again.synthesizerBar, isTrue);
  });
}
