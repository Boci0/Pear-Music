import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/http_client_factory.dart';
import 'package:peerm_app/services/update_service.dart';
import 'package:peerm_app/services/youtube_service.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('peerm_resumable_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Uint8List makePayload(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = (i * 31 + 7) & 0xFF;
    }
    return bytes;
  }

  String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  test('resumes via HTTP Range into .part on mirror failover after mid-stream drop', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final payload = makePayload(32768);
      final expected = sha256Hex(payload);
      final split = 12000;
      String? mirror2RangeHeader;

      final mirror1 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final mirror2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        mirror1.listen((req) async {
          final socket = await req.response.detachSocket(writeHeaders: false);
          socket.add(
            ascii.encode(
              'HTTP/1.1 200 OK\r\n'
              'Content-Length: ${payload.length}\r\n'
              'Connection: close\r\n\r\n',
            ),
          );
          socket.add(payload.sublist(0, split));
          await socket.flush();
          socket.destroy();
        });

        mirror2.listen((req) async {
          mirror2RangeHeader = req.headers.value(HttpHeaders.rangeHeader);
          final rangeMatch = RegExp(r'^bytes=(\d+)-$').firstMatch(
            mirror2RangeHeader ?? '',
          );
          if (rangeMatch == null) {
            req.response.statusCode = HttpStatus.ok;
            req.response.contentLength = payload.length;
            req.response.add(payload);
          } else {
            final start = int.parse(rangeMatch.group(1)!);
            final tail = payload.sublist(start);
            req.response.statusCode = HttpStatus.partialContent;
            req.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-${payload.length - 1}/${payload.length}',
            );
            req.response.contentLength = tail.length;
            req.response.add(tail);
          }
          await req.response.close();
        });

        final dest = File('${tempDir.path}${Platform.pathSeparator}update.zip');
        final progress = <(int, int)>[];
        final err = await UpdateService.downloadVerifiedZipForTesting(
          [
            'http://127.0.0.1:${mirror1.port}/update.zip',
            'http://127.0.0.1:${mirror2.port}/update.zip',
          ],
          dest,
          expected,
          onProgress: (r, t) => progress.add((r, t)),
        );

        expect(err, isNull);
        expect(mirror2RangeHeader, 'bytes=$split-');
        expect(await dest.exists(), isTrue);
        expect(await dest.readAsBytes(), payload);
        expect(await File('${dest.path}.part').exists(), isFalse);
        expect(await File('${dest.path}.part.meta').exists(), isFalse);
        expect(progress.last, (payload.length, payload.length));
      } finally {
        await mirror1.close(force: true);
        await mirror2.close(force: true);
      }
    }, _RealHttpOverrides());
  });

  test('discards stale .part when expected SHA-256 identity changes', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final payload = makePayload(8192);
      final expected = sha256Hex(payload);
      String? observedRange;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        server.listen((req) async {
          observedRange = req.headers.value(HttpHeaders.rangeHeader);
          req.response.statusCode = HttpStatus.ok;
          req.response.contentLength = payload.length;
          req.response.add(payload);
          await req.response.close();
        });

        final dest = File('${tempDir.path}${Platform.pathSeparator}update.zip');
        await File('${dest.path}.part').writeAsBytes(List<int>.filled(4096, 99));
        await File('${dest.path}.part.meta').writeAsString('0' * 64);

        final err = await UpdateService.downloadVerifiedZipForTesting(
          ['http://127.0.0.1:${server.port}/update.zip'],
          dest,
          expected,
        );

        expect(err, isNull);
        expect(observedRange, isNull);
        expect(await dest.readAsBytes(), payload);
      } finally {
        await server.close(force: true);
      }
    }, _RealHttpOverrides());
  });

  test('fails over on stall timeout and preserves .part for second mirror', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final payload = makePayload(16384);
      final expected = sha256Hex(payload);
      final hold = Completer<void>();
      String? mirror2Range;

      final mirror1 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final mirror2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        mirror1.listen((req) async {
          req.response.bufferOutput = false;
          req.response.statusCode = HttpStatus.ok;
          req.response.contentLength = payload.length;
          req.response.add(payload.sublist(0, 5000));
          await req.response.flush();
          await hold.future;
          try {
            await req.response.close();
          } catch (_) {}
        });

        mirror2.listen((req) async {
          mirror2Range = req.headers.value(HttpHeaders.rangeHeader);
          final rangeMatch = RegExp(r'^bytes=(\d+)-$').firstMatch(
            mirror2Range ?? '',
          );
          if (rangeMatch == null) {
            req.response.statusCode = HttpStatus.ok;
            req.response.contentLength = payload.length;
            req.response.add(payload);
            await req.response.close();
            return;
          }
          final start = int.parse(rangeMatch.group(1)!);
          final tail = payload.sublist(start);
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${payload.length - 1}/${payload.length}',
          );
          req.response.contentLength = tail.length;
          req.response.add(tail);
          await req.response.close();
        });

        final dest = File('${tempDir.path}${Platform.pathSeparator}update.zip');
        final err = await UpdateService.downloadVerifiedZipForTesting(
          [
            'http://127.0.0.1:${mirror1.port}/update.zip',
            'http://127.0.0.1:${mirror2.port}/update.zip',
          ],
          dest,
          expected,
          stallTimeout: const Duration(milliseconds: 500),
        );

        expect(err, isNull);
        expect(mirror2Range, 'bytes=5000-');
        expect(await dest.readAsBytes(), payload);
      } finally {
        if (!hold.isCompleted) hold.complete();
        await mirror1.close(force: true);
        await mirror2.close(force: true);
      }
    }, _RealHttpOverrides());
  });

  test('cancels in-flight download promptly via cancelSignal without stranding dest', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final hold = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        server.listen((req) async {
          req.response.statusCode = HttpStatus.ok;
          req.response.contentLength = 1024 * 1024;
          req.response.add(List<int>.filled(4096, 1));
          await req.response.flush();
          await hold.future;
          try {
            await req.response.close();
          } catch (_) {}
        });

        final dest = File('${tempDir.path}${Platform.pathSeparator}update.zip');
        final cancel = Completer<void>();
        var cancelledFlag = false;

        final future = UpdateService.downloadVerifiedZipForTesting(
          ['http://127.0.0.1:${server.port}/update.zip'],
          dest,
          'f' * 64,
          shouldCancel: () => cancelledFlag,
          cancelSignal: cancel.future,
          stallTimeout: const Duration(seconds: 10),
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));
        cancelledFlag = true;
        cancel.complete();

        final err = await future.timeout(const Duration(seconds: 3));
        expect(err, 'Update download cancelled.');
        expect(await dest.exists(), isFalse);
      } finally {
        if (!hold.isCompleted) hold.complete();
        await server.close(force: true);
      }
    }, _RealHttpOverrides());
  });

  test('wipes corrupt full download on checksum mismatch and fails over to clean mirror', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final payload = makePayload(4096);
      final corrupt = Uint8List.fromList(List<int>.filled(4096, 0xAA));
      final expected = sha256Hex(payload);
      String? mirror2Range;

      final badMirror = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final goodMirror = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        badMirror.listen((req) async {
          req.response.statusCode = HttpStatus.ok;
          req.response.contentLength = corrupt.length;
          req.response.add(corrupt);
          await req.response.close();
        });
        goodMirror.listen((req) async {
          mirror2Range = req.headers.value(HttpHeaders.rangeHeader);
          req.response.statusCode = HttpStatus.ok;
          req.response.contentLength = payload.length;
          req.response.add(payload);
          await req.response.close();
        });

        final dest = File('${tempDir.path}${Platform.pathSeparator}update.zip');
        final err = await UpdateService.downloadVerifiedZipForTesting(
          [
            'http://127.0.0.1:${badMirror.port}/update.zip',
            'http://127.0.0.1:${goodMirror.port}/update.zip',
          ],
          dest,
          expected,
        );

        expect(err, isNull);
        expect(mirror2Range, isNull);
        expect(await dest.readAsBytes(), payload);
      } finally {
        await badMirror.close(force: true);
        await goodMirror.close(force: true);
      }
    }, _RealHttpOverrides());
  });

  test('recovers from HTTP 416 by wiping oversized .part and restarting cleanly', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final payload = makePayload(4096);
      final expected = sha256Hex(payload);
      var requests = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        server.listen((req) async {
          requests++;
          if (req.headers.value(HttpHeaders.rangeHeader) != null) {
            req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            await req.response.close();
            return;
          }
          req.response.statusCode = HttpStatus.ok;
          req.response.contentLength = payload.length;
          req.response.add(payload);
          await req.response.close();
        });

        final dest = File('${tempDir.path}${Platform.pathSeparator}update.zip');
        await File('${dest.path}.part').writeAsBytes(List<int>.filled(9999, 5));
        await File('${dest.path}.part.meta').writeAsString(expected);

        final err = await UpdateService.downloadVerifiedZipForTesting(
          ['http://127.0.0.1:${server.port}/update.zip'],
          dest,
          expected,
        );

        expect(err, isNull);
        expect(requests, 2);
        expect(await dest.readAsBytes(), payload);
      } finally {
        await server.close(force: true);
      }
    }, _RealHttpOverrides());
  });

  test('YoutubeService resolver download uses .part and never strands partial .new', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final payload = makePayload(6000);
      final expected = sha256Hex(payload);
      var attempt = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        server.listen((req) async {
          attempt++;
          if (attempt == 1) {
            final socket = await req.response.detachSocket(writeHeaders: false);
            socket.add(
              ascii.encode(
                'HTTP/1.1 200 OK\r\n'
                'Content-Length: ${payload.length}\r\n'
                'Connection: close\r\n\r\n',
              ),
            );
            socket.add(payload.sublist(0, 2500));
            await socket.flush();
            socket.destroy();
            return;
          }
          final range = req.headers.value(HttpHeaders.rangeHeader);
          final start = int.parse(
            RegExp(r'^bytes=(\d+)-$').firstMatch(range!)!.group(1)!,
          );
          final tail = payload.sublist(start);
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${payload.length - 1}/${payload.length}',
          );
          req.response.contentLength = tail.length;
          req.response.add(tail);
          await req.response.close();
        });

        final dest = File('${tempDir.path}${Platform.pathSeparator}yt-dlp.exe.new');
        final ok1 = await YoutubeService.downloadResolverAssetForTesting(
          baseUrl: 'http://127.0.0.1:${server.port}',
          assetName: 'yt-dlp.exe',
          expectedSha256: expected,
          destFile: dest,
        );
        expect(ok1, isFalse);
        expect(await dest.exists(), isFalse,
            reason: 'partial .new binary must never be stranded before SHA-256 passes');
        expect(await File('${dest.path}.part').exists(), isTrue);

        final ok2 = await YoutubeService.downloadResolverAssetForTesting(
          baseUrl: 'http://127.0.0.1:${server.port}',
          assetName: 'yt-dlp.exe',
          expectedSha256: expected,
          destFile: dest,
        );
        expect(ok2, isTrue);
        expect(await dest.exists(), isTrue);
        expect(await dest.readAsBytes(), payload);
        expect(await File('${dest.path}.part').exists(), isFalse);
      } finally {
        await server.close(force: true);
      }
    }, _RealHttpOverrides());
  });

  test('PearHttpClientFactory creates working IPv4 client with cancellation', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        server.listen((req) async {
          req.response.statusCode = HttpStatus.ok;
          req.response.write('ok');
          await req.response.close();
        });

        final cancel = Completer<void>();
        final client = PearHttpClientFactory.create(cancelSignal: cancel.future);
        try {
          final req = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/ping'),
          );
          final res = await req.close();
          expect(res.statusCode, HttpStatus.ok);
          expect(await res.transform(utf8.decoder).join(), 'ok');
        } finally {
          client.close(force: true);
        }
      } finally {
        await server.close(force: true);
      }
    }, _RealHttpOverrides());
  });
}
