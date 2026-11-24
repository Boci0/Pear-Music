import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/ytdlp_prewarmer.dart';

class _FakeProcess implements Process {
  _FakeProcess(this.pid);

  @override
  final int pid;
  final Completer<int> _exit = Completer<int>();
  bool killed = false;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(0);
    return true;
  }

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();
}

void main() {
  tearDown(() {
    YtDlpPrewarmer.setEnabledForTesting(null);
    YtDlpPrewarmer.debugStartProcess = null;
    YtDlpPrewarmer.idleTimeout = YtDlpPrewarmer.defaultIdleTimeout;
    YtDlpPrewarmer.instance.killSpare();
  });

  group('YtDlpPrewarmer.buildStdinArgs', () {
    test('feeds the URL later over stdin and keeps the caller options', () {
      final args = YtDlpPrewarmer.buildStdinArgs(
        baseArgs: ['-f', 'bestaudio', '--quiet'],
        outputTemplate: r'C:\cache\%(id)s.%(ext)s',
      );

      expect(args, containsAllInOrder(['-f', 'bestaudio', '--quiet']));
      expect(args, containsAllInOrder(['-o', r'C:\cache\%(id)s.%(ext)s']));
      expect(args.sublist(args.length - 2), ['--batch-file', '-']);
      expect(args.any((a) => a.contains('http')), isFalse);
    });
  });

  group('YtDlpPrewarmer', () {
    test('prewarm failures are swallowed and leave no spare', () async {
      await YtDlpPrewarmer.instance.prewarm(
        bin: r'C:\definitely\not\here\yt-dlp.exe',
        baseArgs: const ['-f', 'bestaudio'],
        outputTemplate: r'C:\cache\%(id)s.%(ext)s',
      );
      expect(YtDlpPrewarmer.instance.hasSpare, isFalse);
      expect(YtDlpPrewarmer.instance.sparePid, isNull);
    });

    test('startFetch returns null when no process can be started', () async {
      final process = await YtDlpPrewarmer.instance.startFetch(
        url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        bin: r'C:\definitely\not\here\yt-dlp.exe',
        baseArgs: const ['-f', 'bestaudio'],
        outputTemplate: r'C:\cache\%(id)s.%(ext)s',
      );
      expect(process, isNull);
    });

    test('disable switch is respected', () async {
      YtDlpPrewarmer.setEnabledForTesting(false);
      expect(YtDlpPrewarmer.enabled, isFalse);

      await YtDlpPrewarmer.instance.prewarm(
        bin: r'C:\definitely\not\here\yt-dlp.exe',
        baseArgs: const [],
        outputTemplate: 'x',
      );
      expect(YtDlpPrewarmer.instance.hasSpare, isFalse);

      YtDlpPrewarmer.setEnabledForTesting(true);
      expect(YtDlpPrewarmer.enabled, isTrue);
    });

    test('idle spare is killed after idleTimeout and re-armed on next prewarm',
        () async {
      YtDlpPrewarmer.setEnabledForTesting(true);
      YtDlpPrewarmer.idleTimeout = const Duration(milliseconds: 40);
      final spawned = <_FakeProcess>[];
      var nextPid = 1000;
      YtDlpPrewarmer.debugStartProcess = (_, _) async {
        final p = _FakeProcess(nextPid++);
        spawned.add(p);
        return p;
      };

      await YtDlpPrewarmer.instance.prewarm(
        bin: 'yt-dlp.exe',
        baseArgs: const ['-f', 'bestaudio'],
        outputTemplate: r'C:\cache\%(id)s.%(ext)s',
      );
      expect(YtDlpPrewarmer.instance.hasSpare, isTrue);
      expect(spawned, hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(spawned.first.killed, isTrue);
      expect(YtDlpPrewarmer.instance.hasSpare, isFalse);

      await YtDlpPrewarmer.instance.prewarm(
        bin: 'yt-dlp.exe',
        baseArgs: const ['-f', 'bestaudio'],
        outputTemplate: r'C:\cache\%(id)s.%(ext)s',
      );
      expect(YtDlpPrewarmer.instance.hasSpare, isTrue);
      expect(spawned, hasLength(2));
    });
  });
}
