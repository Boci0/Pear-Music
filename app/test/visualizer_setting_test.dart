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

  test('the visualizer is on by default on Android too', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final identity = await load();
    expect(identity.synthesizerBar, isTrue);
    expect(identity.visualizerAudioExplained, isFalse,
        reason: 'the audio access is explained the first time it is shown');
  });

  test('bars on the mini player are opt-in and the choice is kept', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final identity = await load();
    expect(identity.miniVisualizer, isFalse);

    await identity.setMiniVisualizer(true);
    final prefs = await SharedPreferences.getInstance();
    expect(IdentityService(prefs).miniVisualizer, isTrue);

    await identity.setMiniVisualizer(false);
    expect(IdentityService(prefs).miniVisualizer, isFalse);
  });

  test('having been told what the audio access is for is remembered', () async {
    final identity = await load();
    await identity.setVisualizerAudioExplained(true);
    final prefs = await SharedPreferences.getInstance();
    expect(IdentityService(prefs).visualizerAudioExplained, isTrue);
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
