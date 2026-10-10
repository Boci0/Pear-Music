import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/live_hls_proxy.dart';

/// A tiny HLS origin: a sliding media playlist whose window advances each
/// time it is read, ending after [total] segments. Segment n is the bytes
/// "[n]" so the order of the relayed stream is easy to check.
class _Origin {
  _Origin({required this.total});

  final int total;
  final int window = 3;
  int reads = 0;

  /// Answers every playlist read with a server error.
  bool failing = false;
  late final HttpServer server;
  String get playlistUrl => 'http://127.0.0.1:${server.port}/live.m3u8';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      final path = req.uri.path;
      if (path == '/live.m3u8' && failing) {
        req.response
          ..statusCode = 500
          ..close();
      } else if (path == '/live.m3u8') {
        // The live edge moves one segment per read, starting with 4 present.
        final head = (4 + reads).clamp(0, total);
        reads++;
        final first = (head - window).clamp(0, head);
        final buf = StringBuffer('#EXTM3U\n#EXT-X-VERSION:3\n')
          ..write('#EXT-X-TARGETDURATION:5\n')
          ..write('#EXT-X-MEDIA-SEQUENCE:$first\n');
        for (var n = first; n < head; n++) {
          buf.write('#EXTINF:5.0,\nseg/$n\n');
        }
        if (head >= total) buf.write('#EXT-X-ENDLIST\n');
        req.response
          ..write(buf.toString())
          ..close();
      } else if (path.startsWith('/seg/')) {
        req.response
          ..write('[${path.substring(5)}]')
          ..close();
      } else {
        req.response
          ..statusCode = 404
          ..close();
      }
    });
  }

  Future<void> stop() => server.close(force: true);
}

Future<String> _read(Uri uri) async {
  final client = HttpClient();
  try {
    final res = await (await client.getUrl(uri)).close();
    return await res.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

void main() {
  tearDown(LiveHlsProxy.stop);

  test('relays new segments in order, once each, and ends with the playlist',
      () async {
    final origin = _Origin(total: 8);
    await origin.start();
    addTearDown(origin.stop);

    final uri = await LiveHlsProxy.serve(
      origin.playlistUrl,
      poll: const Duration(milliseconds: 20),
      startBack: 2,
    );
    final text = await _read(uri).timeout(const Duration(seconds: 10));

    // Starts two segments behind the first live edge (segments 0..3 present,
    // so 2 and 3), then follows without repeating or skipping.
    expect(text, '[2][3][4][5][6][7]');
  });

  test('a stalled playlist ends the stream instead of hanging', () async {
    final origin = _Origin(total: 8);
    await origin.start();
    final uri = await LiveHlsProxy.serve(
      origin.playlistUrl,
      poll: const Duration(milliseconds: 10),
    );
    // Reading starts the relay; the origin then disappears.
    final first = Completer<void>();
    final client = HttpClient();
    final res = await (await client.getUrl(uri)).close();
    final chunks = StringBuffer();
    final done = res.transform(utf8.decoder).listen((c) {
      chunks.write(c);
      if (!first.isCompleted) first.complete();
    }).asFuture<void>();
    await first.future.timeout(const Duration(seconds: 5));
    origin.failing = true;
    await done.timeout(const Duration(seconds: 10));
    client.close(force: true);
    await origin.stop();
    expect(chunks.toString(), startsWith('[2]'));
  });
}
