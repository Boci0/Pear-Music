import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/controllers/app_controller.dart';
import 'package:peerm_app/services/history_service.dart';
import 'package:peerm_app/services/identity_service.dart';
import 'package:peerm_app/services/library_service.dart';
import 'package:peerm_app/services/player_service.dart';
import 'package:peerm_app/services/test_control.dart';
import 'package:peerm_app/services/youtube_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const token = '0123456789abcdef-secret';

  test('the control port needs both flags and a long enough secret', () {
    expect(parseControlArgs(const []), isNull);
    expect(parseControlArgs(const ['--control-port=8800']), isNull);
    expect(parseControlArgs(const ['--control-token=$token']), isNull);
    expect(
      parseControlArgs(const ['--control-port=8800', '--control-token=short']),
      isNull,
    );
    expect(
      parseControlArgs(const ['--control-port=99999', '--control-token=$token']),
      isNull,
    );
    final ok = parseControlArgs(
      const ['--beta', '--control-port=8800', '--control-token=$token'],
    );
    expect(ok?.port, 8800);
    expect(ok?.token, token);
  });

  test('a launch without the flags opens nothing', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final history = HistoryService(prefs);
    final player = PlayerService(library, identity: identity, history: history);
    final controller = AppController(
      identity: identity,
      library: library,
      player: player,
      youtube: YoutubeService(),
      history: history,
    );
    expect(await startTestControl(controller, const ['--beta']), isNull);
    player.dispose();
  });

  test('only a request with the secret, from a non-browser, is answered',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final identity = IdentityService(prefs);
    final library = LibraryService();
    final history = HistoryService(prefs);
    final player = PlayerService(library, identity: identity, history: history);
    final controller = AppController(
      identity: identity,
      library: library,
      player: player,
      youtube: YoutubeService(),
      history: history,
    );
    final server = await startTestControl(
      controller,
      const ['--control-port=0', '--control-token=$token'],
    );
    expect(server, isNotNull);
    addTearDown(() async {
      await server!.close(force: true);
      player.dispose();
    });

    // The test binding answers HTTP with 400; this talks to the local server.
    HttpOverrides.global = null;
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    Future<(int, String)> get(String path,
        {String? withToken, Map<String, String> headers = const {}}) async {
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:${server!.port}$path'));
      if (withToken != null) req.headers.set('x-control-token', withToken);
      headers.forEach(req.headers.set);
      final res = await req.close();
      return (res.statusCode, await res.transform(utf8.decoder).join());
    }

    expect((await get('/state')).$1, 403);
    expect((await get('/state', withToken: 'wrong-wrong-wrong-wrong')).$1, 403);
    expect(
      (await get('/state', withToken: token, headers: {'Origin': 'https://x'}))
          .$1,
      403,
    );
    final ok = await get('/state', withToken: token);
    expect(ok.$1, 200);
    final state = jsonDecode(ok.$2) as Map<String, dynamic>;
    expect(state['playing'], isFalse);
    expect(state['live'], isFalse);
    expect((await get('/nope', withToken: token)).$1, 404);
    expect((await get('/play', withToken: token)).$1, 400);
  });
}
