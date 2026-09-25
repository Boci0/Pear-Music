import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/services/growing_file_audio_source.dart';

/// Guards playing a file while yt-dlp is still writing it (Android's play
/// while caching): reads wait for new bytes instead of ending early, stop
/// once the download is done, and seeks read the right range.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('peerm_growing_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  GrowingFileAudioSource source(
    String path,
    Completer<void> done, {
    int? expectedLength,
  }) => GrowingFileAudioSource(
    path: path,
    done: done.future,
    expectedLength: expectedLength,
    pollInterval: const Duration(milliseconds: 5),
    openTimeout: const Duration(seconds: 5),
  );

  test('follows the file as it is written and ends with the download',
      () async {
    final path = p.join(dir.path, 'track.m4a');
    final done = Completer<void>();
    final src = source(path, done);

    // The file does not exist yet when playback asks for it.
    final response = await Future(() async {
      final pending = src.request();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      File(path).writeAsBytesSync([1, 2, 3]);
      return pending;
    });
    final received = <int>[];
    final finished = response.stream.forEach(received.addAll);

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(received, [1, 2, 3], reason: 'bytes already on disk play at once');

    File(path).writeAsBytesSync([4, 5], mode: FileMode.append);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(received, [1, 2, 3, 4, 5],
        reason: 'reaching the end waits for more instead of stopping');

    File(path).writeAsBytesSync([6], mode: FileMode.append);
    done.complete();
    await finished.timeout(const Duration(seconds: 2));
    expect(received, [1, 2, 3, 4, 5, 6]);
    await src.close();
  });

  test('a range request with a known size serves just that range', () async {
    final path = p.join(dir.path, 'track.webm');
    File(path).writeAsBytesSync(List.generate(10, (i) => i));
    final done = Completer<void>()..complete();
    final src = source(path, done, expectedLength: 10);

    final response = await src.request(4, 7);
    expect(response.sourceLength, 10);
    expect(response.contentLength, 3);
    expect(response.offset, 4);
    expect(response.rangeRequestsSupported, isTrue);
    expect(await response.stream.expand((b) => b).toList(), [4, 5, 6]);
    await src.close();
  });

  test('without a known size, seeking is not offered', () async {
    final path = p.join(dir.path, 'track.m4a');
    File(path).writeAsBytesSync([9, 9]);
    final src = source(path, Completer<void>()..complete());

    final response = await src.request();
    expect(response.rangeRequestsSupported, isFalse);
    expect(response.sourceLength, isNull);
    expect(await response.stream.expand((b) => b).toList(), [9, 9]);
    await src.close();
  });

  test('a download that ends without a file fails the request', () async {
    final path = p.join(dir.path, 'missing.m4a');
    final done = Completer<void>();
    final src = source(path, done);

    final pending = src.request();
    done.complete();
    await expectLater(pending, throwsA(isA<FileSystemException>()));
  });

  test('keeps reading the original bytes when the file is replaced', () async {
    // yt-dlp's m4a fixup renames a remuxed copy over the file at the end.
    final path = p.join(dir.path, 'track.m4a');
    File(path).writeAsBytesSync([1, 2, 3, 4]);
    final done = Completer<void>();
    final src = source(path, done, expectedLength: 4);

    final first = await src.request(0, 2);
    expect(await first.stream.expand((b) => b).toList(), [1, 2]);

    final remuxed = File(p.join(dir.path, 'track.temp.m4a'))
      ..writeAsBytesSync([7, 7, 7, 7, 7, 7]);
    remuxed.renameSync(path);
    done.complete();

    final rest = await src.request(2, 4);
    expect(await rest.stream.expand((b) => b).toList(), [3, 4]);
    await src.close();
  },
      // Windows cannot rename over a file that is open; the replace only
      // happens on Android, where this matters.
      skip: Platform.isWindows);
}
