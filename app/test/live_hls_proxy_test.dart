import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/live_hls_proxy.dart';

/// A tiny HLS origin: a sliding media playlist whose window advances each
/// time it is read, ending after [total] segments. Segment n is the bytes
/// "[n]" so the order of the relayed stream is easy to check.
class _Origin {
  _Origin({required this.total, this.window = 3, this.startHead = 4});

  final int total;
  final int window;

  /// How many segments exist at the first read.
  final int startHead;
  int reads = 0;

  /// Answers every playlist read with a server error.
  bool failing = false;

  /// The Accept-Encoding of each playlist read: the real playlist is ~900 KB
  /// of text that only costs ~12 KB when the relay asks for gzip.
  final acceptEncodings = <String?>[];
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
        acceptEncodings.add(req.headers.value(HttpHeaders.acceptEncodingHeader));
        // The live edge moves one segment per read, starting with 4 present.
        final head = (startHead + reads).clamp(0, total);
        reads++;
        final first = (head - window).clamp(0, head);
        final buf = StringBuffer('#EXTM3U\n#EXT-X-VERSION:3\n')
          ..write('#EXT-X-TARGETDURATION:5\n')
          ..write('#EXT-X-MEDIA-SEQUENCE:$first\n');
        for (var n = first; n < head; n++) {
          buf.write('#EXTINF:0.2,\nseg/$n\n');
        }
        if (head >= total) buf.write('#EXT-X-ENDLIST\n');
        // Like YouTube: the playlist is compressed when the client allows it.
        if (acceptEncodings.last?.contains('gzip') ?? false) {
          req.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
          req.response
            ..add(gzip.encode(utf8.encode(buf.toString())))
            ..close();
        } else {
          req.response
            ..write(buf.toString())
            ..close();
        }
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
    expect(origin.acceptEncodings, isNotEmpty);
    // The count is what crossed the network, compressed playlists included.
    expect(LiveHlsProxy.bytesUsed.value, greaterThan(0));
    expect(origin.acceptEncodings.every((e) => e?.contains('gzip') ?? false), isTrue);
  });

  test('audio is handed over at playing speed, not in segment bursts',
      () async {
    // Segments 2 and 3 only; each plays for 0.2 s. The first goes out at
    // once, the second is spread over its own 0.2 s in 100 ms pieces.
    final origin = _Origin(total: 4);
    await origin.start();
    addTearDown(origin.stop);
    final uri = await LiveHlsProxy.serve(
      origin.playlistUrl,
      poll: const Duration(milliseconds: 20),
      startBack: 2,
    );
    final client = HttpClient();
    final res = await (await client.getUrl(uri)).close();
    final arrivals = <int>[];
    final text = StringBuffer();
    final clock = Stopwatch()..start();
    await for (final chunk in res) {
      arrivals.add(clock.elapsedMilliseconds);
      text.write(utf8.decode(chunk));
    }
    client.close(force: true);
    expect(text.toString(), '[2][3]');
    expect(arrivals.length, greaterThanOrEqualTo(3));
    expect(arrivals.last - arrivals.first, greaterThanOrEqualTo(80));
  });

  test('a rewound open starts further back and the window is reported',
      () async {
    final origin = _Origin(total: 6);
    await origin.start();
    addTearDown(origin.stop);
    await LiveHlsProxy.serve(
      origin.playlistUrl,
      poll: const Duration(milliseconds: 20),
      startBack: 2,
    );
    // Segments 1..3 are present at first (0.2 s each). Asking for a second
    // back reaches past all of them, so the stream starts at the oldest,
    // where the default start would have been at 2.
    final uri = LiveHlsProxy.address(behind: 1)!;
    expect(uri.queryParameters['back'], '1');
    final text = await _read(uri).timeout(const Duration(seconds: 10));

    expect(text, '[1][2][3][4][5]');
    expect(LiveHlsProxy.windowSeconds.value, closeTo(0.6, 0.001));
    expect(LiveHlsProxy.address()!.query, isEmpty);
  });

  test('a rewound open plays the whole backlog in order, none of it skipped',
      () async {
    // 20 segments already exist; a start at the oldest has more backlog than
    // the relay queues at once (12), and none of it may be dropped.
    final origin = _Origin(total: 20, window: 20, startHead: 20);
    await origin.start();
    addTearDown(origin.stop);
    await LiveHlsProxy.serve(
      origin.playlistUrl,
      poll: const Duration(milliseconds: 20),
    );
    final text = await _read(LiveHlsProxy.address(behind: 60)!)
        .timeout(const Duration(seconds: 20));

    expect(text, [for (var n = 0; n < 20; n++) '[$n]'].join());
  });

  test('a refused link is swapped for a fresh one instead of ending the stream',
      () async {
    final refused = _Origin(total: 8)..failing = true;
    final fresh = _Origin(total: 6);
    await refused.start();
    await fresh.start();
    addTearDown(refused.stop);
    addTearDown(fresh.stop);

    var lookups = 0;
    final uri = await LiveHlsProxy.serve(
      refused.playlistUrl,
      poll: const Duration(milliseconds: 10),
      startBack: 2,
      refresh: () async {
        lookups++;
        return fresh.playlistUrl;
      },
    );
    final text = await _read(uri).timeout(const Duration(seconds: 10));

    expect(lookups, 1);
    expect(text, startsWith('[2][3]'));
    expect(text, endsWith('[5]'));
  });

  test('a link that cannot be refreshed still ends the stream', () async {
    final refused = _Origin(total: 8)..failing = true;
    await refused.start();
    addTearDown(refused.stop);

    var lookups = 0;
    final uri = await LiveHlsProxy.serve(
      refused.playlistUrl,
      poll: const Duration(milliseconds: 10),
      refresh: () async {
        lookups++;
        return null;
      },
    );
    final text = await _read(uri).timeout(const Duration(seconds: 10));

    expect(lookups, 1);
    expect(text, isEmpty);
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
