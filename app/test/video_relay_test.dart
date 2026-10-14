import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/video_relay.dart';

/// A stand-in for YouTube's media server: one file, ranged reads, and a log of
/// the ranges it was asked for.
class _Upstream {
  _Upstream(this.body);
  final Uint8List body;
  final List<String> requests = [];
  late final HttpServer server;
  Map<String, String> lastHeaders = {};

  Future<String> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final range = req.headers.value(HttpHeaders.rangeHeader);
      requests.add(range ?? '-');
      lastHeaders = {
        'user-agent': req.headers.value('user-agent') ?? '',
        'origin': req.headers.value('origin') ?? '',
      };
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range ?? '');
      final start = int.parse(m!.group(1)!);
      final end = m.group(2)!.isEmpty
          ? body.length - 1
          : int.parse(m.group(2)!).clamp(0, body.length - 1);
      req.response.statusCode = 206;
      req.response.headers
        ..set('content-range', 'bytes $start-$end/${body.length}')
        ..contentLength = end - start + 1;
      req.response.add(body.sublist(start, end + 1));
      await req.response.close();
    });
    return 'http://127.0.0.1:${server.port}/v.mp4';
  }
}

typedef _Answer = (int status, List<int> bytes, Map<String, String> headers);

Future<_Answer> _get(Uri url, String? range) async {
  final client = HttpClient();
  final req = await client.getUrl(url);
  if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
  final res = await req.close();
  final bytes = <int>[];
  await for (final b in res) {
    bytes.addAll(b);
  }
  final headers = <String, String>{
    'content-range': res.headers.value('content-range') ?? '',
    'accept-ranges': res.headers.value('accept-ranges') ?? '',
  };
  client.close();
  return (res.statusCode, bytes, headers);
}

void main() {
  late _Upstream upstream;
  late String url;

  setUp(() async {
    final size = VideoRelay.windowBytes * 2 + 12345;
    upstream = _Upstream(
      Uint8List.fromList(List<int>.generate(size, (i) => i % 251)),
    );
    url = await upstream.start();
  });

  tearDown(() async {
    VideoRelay.stop();
    await upstream.server.close(force: true);
  });

  test('a read is answered one window at a time and counted', () async {
    final local = await VideoRelay.serve(
      url,
      headers: const {'User-Agent': 'pear-test', 'Origin': 'https://o'},
    );
    final total = upstream.body.length;
    final (status, bytes, headers) = await _get(local, 'bytes=0-');
    expect(status, 206);
    // Only the first window, with the true length of the file in the header,
    // so the player knows to come back for the rest.
    expect(bytes.length, VideoRelay.windowBytes);
    expect(bytes[300], upstream.body[300]);
    expect(headers['content-range'], 'bytes 0-${VideoRelay.windowBytes - 1}/$total');
    expect(headers['accept-ranges'], 'bytes');
    expect(upstream.requests, ['bytes=0-${VideoRelay.windowBytes - 1}']);
    expect(upstream.lastHeaders['user-agent'], 'pear-test');
    expect(upstream.lastHeaders['origin'], 'https://o');
    expect(VideoRelay.bytesUsed.value, VideoRelay.windowBytes);
  });

  test('asking again from where a window ended gives the whole file', () async {
    final local = await VideoRelay.serve(url);
    final got = <int>[];
    while (got.length < upstream.body.length) {
      final (status, bytes, _) = await _get(local, 'bytes=${got.length}-');
      expect(status, 206);
      expect(bytes, isNotEmpty);
      got.addAll(bytes);
    }
    expect(got.length, upstream.body.length);
    expect(got.sublist(VideoRelay.windowBytes, VideoRelay.windowBytes + 100),
        upstream.body.sublist(VideoRelay.windowBytes, VideoRelay.windowBytes + 100));
    expect(VideoRelay.bytesUsed.value, upstream.body.length);
  });

  test('the start of the file is read once, however often it is asked for', () async {
    final local = await VideoRelay.serve(url);
    final first = await _get(local, 'bytes=0-');
    final again = await _get(local, 'bytes=0-');
    expect(again.$2.length, VideoRelay.windowBytes);
    expect(again.$2.sublist(0, 64), first.$2.sublist(0, 64));
    expect(again.$3['content-range'], first.$3['content-range']);
    // One window over the network, two answered.
    expect(upstream.requests.length, 1);
    expect(VideoRelay.bytesUsed.value, VideoRelay.windowBytes);
  });

  test('a seek is a window from the middle, and a short last one is exact', () async {
    final local = await VideoRelay.serve(url);
    final from = VideoRelay.windowBytes * 2;
    final (status, bytes, headers) = await _get(local, 'bytes=$from-');
    expect(status, 206);
    expect(bytes.length, upstream.body.length - from);
    expect(bytes.first, upstream.body[from]);
    expect(headers['content-range'], startsWith('bytes $from-'));
    expect(VideoRelay.bytesUsed.value, upstream.body.length - from);
  });

  test('a jump costs one window, not the rest of the file', () async {
    final local = await VideoRelay.serve(url);
    final (_, bytes, _) = await _get(local, 'bytes=1000-');
    expect(bytes.length, VideoRelay.windowBytes);
    expect(VideoRelay.bytesUsed.value, VideoRelay.windowBytes);
  });

  test('a refused link is looked up again once, then the read goes on', () async {
    final refusing = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var refused = 0;
    refusing.listen((req) async {
      refused++;
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
    });
    var relinks = 0;
    final local = await VideoRelay.serve(
      'http://127.0.0.1:${refusing.port}/old.mp4',
      relink: () async {
        relinks++;
        return (url: url, headers: <String, String>{});
      },
    );
    // Two reads at once: one lookup serves both.
    final results = await Future.wait([
      _get(local, 'bytes=0-'),
      _get(local, 'bytes=0-'),
    ]);
    expect(results[0].$1, 206);
    expect(results[0].$2.length, VideoRelay.windowBytes);
    expect(results[1].$2.length, VideoRelay.windowBytes);
    expect(relinks, 1);
    expect(refused, greaterThanOrEqualTo(1));
    await refusing.close(force: true);
  });

  test('a link still refused after the new one fails the read', () async {
    final refusing = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    refusing.listen((req) async {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
    });
    final bad = 'http://127.0.0.1:${refusing.port}/x.mp4';
    final local = await VideoRelay.serve(
      bad,
      relink: () async => (url: bad, headers: <String, String>{}),
    );
    final (status, bytes, _) = await _get(local, 'bytes=0-');
    expect(status, 502);
    expect(bytes, isEmpty);
    await refusing.close(force: true);
  });

  test('parseRange reads the forms a player sends', () {
    expect(VideoRelay.parseRange('bytes=0-')?.start, 0);
    expect(VideoRelay.parseRange('bytes=10-19')?.end, 19);
    expect(VideoRelay.parseRange('bytes=-500'), isNull);
    expect(VideoRelay.parseRange(null), isNull);
  });
}
