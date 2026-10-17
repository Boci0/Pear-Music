import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../controllers/app_controller.dart';
import '../main.dart' show PearMusicApp;
import '../screens/home_shell.dart';
import '../screens/player_screen.dart';
import '../theme/pear_style.dart';
import '../widgets/pear_page_route.dart';
import 'debug_log.dart';
import 'video_service.dart';
import 'visualizer_feed.dart';
import 'window_occlusion.dart';
import 'youtube_search_service.dart';

/// The control port: lets an automated check drive a running build without a
/// mouse, a keyboard or a window in front.
///
/// It exists only when the app is started with BOTH
/// `--control-port=<port>` and `--control-token=<secret>` (a normal launch
/// has neither, so nothing listens). It binds to 127.0.0.1, answers only
/// requests that carry the secret in `X-Control-Token`, and refuses anything
/// that looks like a web page (an `Origin` header, or a `Host` that is not the
/// loopback address) so a browser cannot be made to call it.
///
///   /state                  what is playing (JSON)
///   /search?q=&live=0|1     search; rows are kept for /play?i=
///   /play?i=N | ?id=VIDEO   play search row N, or a video id
///   /toggle /pause /next /prev
///   /volume?v=0..1          player volume (this is the saved setting)
///   /seek?ms=
///   /liveseek?behind=S      rewind a live stream S seconds; /golive returns
///   /library                the library's songs (JSON)
///   /playlocal?i=N          play library song N (no network)
///   /import?path=           copy a file into the library (JSON: added)
///   /expand                 open the Now Playing pane, as a tap on it does
///   /remove?id=             take a song out of the library again
///   /video?on=1|0           show or hide the picture; the reply is its state
///   /viz?hold=1|0           what the visualizer feed saw since the last call
///                           (hold=1 keeps a client on the feed, hold=0 drops it)
///   /log?n=60               the last lines of the debug log
///   /style?v=glass|frosted|solid  switch the look; the reply is the style in use
///   /player                 open the full player screen, as tapping the bar does
///   /quit                   exit the app
class ControlSettings {
  const ControlSettings(this.port, this.token);
  final int port;
  final String token;
}

/// Reads the two flags from the launch arguments; null unless both are valid.
ControlSettings? parseControlArgs(List<String> args) {
  int? port;
  String? token;
  for (final a in args) {
    if (a.startsWith('--control-port=')) {
      port = int.tryParse(a.substring('--control-port='.length));
    } else if (a.startsWith('--control-token=')) {
      token = a.substring('--control-token='.length);
    }
  }
  if (port == null || port < 0 || port > 65535) return null;
  if (token == null || token.length < 16) return null;
  return ControlSettings(port, token);
}

const bool _controlFileEnabled = bool.fromEnvironment('PEAR_CONTROL_FILE');

/// The launch arguments plus the control flags from `control.txt` in the
/// phone's external app folder (`port token` on one line, put there over adb),
/// since intent arguments never reach `main` there.
Future<List<String>> controlArgsWithFile(List<String> args) async {
  // Compiled in only for check builds: on older Android another app could
  // write that file, and the port can import and remove songs.
  if (!_controlFileEnabled || !Platform.isAndroid) return args;
  try {
    final dir = await getExternalStorageDirectory();
    if (dir == null) return args;
    final file = File('${dir.path}/control.txt');
    if (!await file.exists()) return args;
    final parts = (await file.readAsString()).trim().split(RegExp(r'\s+'));
    if (parts.length < 2) return args;
    return [...args, '--control-port=${parts[0]}', '--control-token=${parts[1]}'];
  } catch (_) {
    return args;
  }
}

/// Starts the control port when the launch arguments ask for it. Returns the
/// server (for tests and shutdown) or null when it is not enabled.
Future<HttpServer?> startTestControl(
  AppController controller,
  List<String> args, {
  VideoService? video,
}) async {
  final settings = parseControlArgs(args);
  if (settings == null) return null;
  try {
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      settings.port,
    );
    final results = <YouTubeSearchResult>[];
    var vizHeld = false;
    server.listen((req) async {
      final res = req.response;
      try {
        if (!_allowed(req, settings.token, server.port)) {
          res.statusCode = HttpStatus.forbidden;
          await res.close();
          return;
        }
        final player = controller.player;
        final q = req.uri.queryParameters;
        Object? body;
        switch (req.uri.path) {
          case '/state':
            final song = player.currentSong;
            body = {
              'song': song?.title,
              'id': song?.id,
              'playing': player.playing,
              'buffering': player.isBuffering,
              'live': player.isLive,
              'positionMs': player.position?.inMilliseconds,
              'durationMs': player.duration?.inMilliseconds,
              'volume': player.volume,
              'covered': WindowOcclusion.covered.value,
              'format': player.currentLoadedFormat,
              'route': player.currentRouteType.name,
              'loadMs': player.lastTrackLoadMs,
              'queueLength': player.queue.length,
              'error': player.playbackError?.label,
              'liveBehind': player.liveBehind,
              'liveWindow': player.liveWindow,
              if (video != null) 'video': video.status,
            };
          case '/search':
            final query = q['q'] ?? '';
            final live = q['live'] == '1';
            final found = live
                ? await YouTubeSearchService.searchLive(query)
                : await YouTubeSearchService.search(
                    query,
                    limit: int.tryParse(q['limit'] ?? '') ?? 30,
                    includeLive: true,
                  );
            results
              ..clear()
              ..addAll(found);
            body = [
              for (var i = 0; i < found.length; i++)
                {
                  'i': i,
                  'id': found[i].videoId,
                  'title': found[i].title,
                  'author': found[i].author,
                  'live': found[i].isLive,
                  'seconds': found[i].duration?.inSeconds,
                },
            ];
          case '/play':
            final index = int.tryParse(q['i'] ?? '');
            YouTubeSearchResult? pick;
            if (index != null && index >= 0 && index < results.length) {
              pick = results[index];
            } else if ((q['id'] ?? '').isNotEmpty) {
              pick = YouTubeSearchResult(
                videoId: q['id']!,
                title: q['title'] ?? q['id']!,
                author: '',
              );
            }
            if (pick == null) {
              res.statusCode = HttpStatus.badRequest;
              body = {'error': 'no such row or id'};
            } else {
              unawaited(
                player.playSong(
                  pick.toSong(),
                  queue: [pick.toSong()],
                  sourceId: 'search:streaming',
                  sourceTitle: 'Online Stream',
                ),
              );
              body = {'playing': pick.title};
            }
          case '/toggle':
            await controller.togglePlayback();
            body = {'playing': player.playing};
          case '/pause':
            await player.pause();
            body = {'playing': player.playing};
          case '/next':
            await player.next(userAction: true);
            body = {'ok': true};
          case '/prev':
            await player.previous();
            body = {'ok': true};
          case '/volume':
            final v = double.tryParse(q['v'] ?? '');
            if (v == null) {
              res.statusCode = HttpStatus.badRequest;
              body = {'error': 'v required'};
            } else {
              await player.setVolume(v.clamp(0.0, 1.0));
              body = {'volume': player.volume};
            }
          case '/seek':
            final ms = int.tryParse(q['ms'] ?? '');
            if (ms == null) {
              res.statusCode = HttpStatus.badRequest;
              body = {'error': 'ms required'};
            } else {
              await player.seek(Duration(milliseconds: ms));
              body = {'ok': true};
            }
          case '/liveseek':
            final behind = double.tryParse(q['behind'] ?? '');
            if (behind == null) {
              res.statusCode = HttpStatus.badRequest;
              body = {'error': 'behind (seconds) required'};
            } else {
              await player.seekLive(behind);
              body = {'liveBehind': player.liveBehind};
            }
          case '/golive':
            await player.goLive();
            body = {'liveBehind': player.liveBehind};
          case '/library':
            final songs = controller.library.songs;
            body = [
              for (var i = 0; i < songs.length; i++)
                {'i': i, 'title': songs[i].title, 'bytes': songs[i].size},
            ];
          case '/playlocal':
            final songs = controller.library.songs;
            final index = int.tryParse(q['i'] ?? '');
            if (index == null || index < 0 || index >= songs.length) {
              res.statusCode = HttpStatus.badRequest;
              body = {'error': 'no such library row'};
            } else {
              unawaited(player.playSong(songs[index], queue: songs));
              body = {'playing': songs[index].title};
            }
          case '/import':
            final path = q['path'];
            if (path == null || !File(path).existsSync()) {
              res.statusCode = HttpStatus.badRequest;
              body = {'error': 'no such file'};
            } else {
              final added = await controller.library.addLocalFiles([File(path)]);
              body = {
                'added': added.length,
                'ids': [for (final s in added) s.id],
              };
            }
          case '/expand':
            HomeShell.requestExpandedPane();
            body = {'expanded': true};
          case '/remove':
            // Takes out a song a check imported, so it leaves no trace.
            final known = controller.library.songs
                .where((s) => s.id == q['id'])
                .firstOrNull;
            if (known == null) {
              res.statusCode = HttpStatus.badRequest;
              body = {'error': 'no such song'};
            } else {
              await controller.library.removeSong(known.id);
              body = {'removed': known.title};
            }
          case '/video':
            if (video == null) {
              res.statusCode = HttpStatus.badRequest;
              body = {'error': 'no video service'};
            } else {
              if (q['on'] == '1') video.show();
              if (q['on'] == '0') video.hide();
              body = video.status;
            }
          case '/viz':
            // hold=1 stands in for a mounted visualizer widget (so capture can
            // run with no player view open); hold=0 lets it go.
            if (q['hold'] == '1' && !vizHeld) {
              VisualizerFeed.instance.acquire(player);
              vizHeld = true;
            } else if (q['hold'] == '0' && vizHeld) {
              VisualizerFeed.instance.release();
              vizHeld = false;
            }
            body = VisualizerFeed.instance.takeStats();
          case '/log':
            final n = int.tryParse(q['n'] ?? '') ?? 60;
            body = {'lines': await _logTail(n)};
          case '/style':
            final wanted = q['v'];
            if (wanted != null) {
              await controller.identity.setStyle(PearStyle.parse(wanted));
            }
            body = {'style': controller.identity.style.name};
          case '/player':
            // Opens the full player screen the way a tap on the playing bar
            // does, so a check can measure or screenshot that screen.
            final navigator = PearMusicApp.navigatorKey.currentState;
            if (navigator == null) {
              res.statusCode = HttpStatus.serviceUnavailable;
              body = {'error': 'no navigator yet'};
            } else {
              unawaited(
                navigator.push(
                  PearPageRoute(builder: (_) => const PlayerScreen()),
                ),
              );
              body = {'player': 'opened'};
            }
          case '/quit':
            res.headers.contentType = ContentType.json;
            res.write(jsonEncode({'quitting': true}));
            await res.close();
            exit(0);
          default:
            res.statusCode = HttpStatus.notFound;
            body = {'error': 'unknown path'};
        }
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(body));
        await res.close();
      } catch (e) {
        try {
          res.statusCode = HttpStatus.internalServerError;
          res.write(jsonEncode({'error': '$e'}));
          await res.close();
        } catch (_) {}
      }
    });
    DebugLog.write('[control] Listening on 127.0.0.1:${server.port}');
    return server;
  } catch (e) {
    DebugLog.write('[control] Could not start: $e');
    return null;
  }
}

/// A request is accepted only with the secret, from a client that is not a
/// web page, addressed to the loopback address.
bool _allowed(HttpRequest req, String token, int port) {
  if (req.headers.value('origin') != null) return false;
  final host = req.headers.host;
  if (host != '127.0.0.1') return false;
  final sent = req.headers.value('x-control-token') ?? '';
  if (sent.length != token.length) return false;
  var diff = 0;
  for (var i = 0; i < token.length; i++) {
    diff |= sent.codeUnitAt(i) ^ token.codeUnitAt(i);
  }
  return diff == 0;
}

Future<List<String>> _logTail(int n) async {
  // The in-memory ring is always current; the file is written asynchronously
  // and can trail by a while (or be shared with another running instance).
  final lines = DebugLog.recentLogs;
  return lines.length <= n ? lines : lines.sublist(lines.length - n);
}
