// Does a pre-booted yt-dlp (spawned earlier, waiting on stdin) skip the boot cost?
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final bin = Platform.environment['PEERM_YTDLP'] ??
      r'C:\Users\muhdb\AppData\Local\Programs\Pear Music Beta\yt-dlp.exe';
  final out = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}peerm_prewarm_test')
    ..createSync(recursive: true);

  Future<Process> spawn() => Process.start(bin, [
        '--batch-file', '-',
        '--no-warnings',
        '--quiet',
        '--no-part',
        '-o', '${out.path}${Platform.pathSeparator}%(id)s_%(epoch)s.%(ext)s',
      ]);

  Future<void> feed(Process p, String url) async {
    p.stdin.writeln(url);
    await p.stdin.close();
  }

  Future<int> waitForFile(String marker) async {
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 20000) {
      final files = out
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains(marker))
          .toList();
      if (files.isNotEmpty) return sw.elapsedMilliseconds;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return -1;
  }

  for (final f in out.listSync()) {
    f.deleteSync(recursive: true);
  }

  // Fresh: spawn now, feed immediately.
  final fresh = await spawn();
  fresh.stdout.drain();
  fresh.stderr.drain();
  var sw = Stopwatch()..start();
  await feed(fresh, 'http://127.0.0.1:8123/a.mp3');
  final freshMs = await waitForFile('a_');
  print('fresh spawn + feed: $freshMs ms (total ${sw.elapsedMilliseconds})');
  await fresh.exitCode;

  // Pre-warmed: spawn, let it boot while idle, then feed.
  final warm = await spawn();
  warm.stdout.drain();
  warm.stderr.drain();
  print('pre-booting a spare, waiting 6 s ...');
  await Future<void>.delayed(const Duration(seconds: 6));
  sw = Stopwatch()..start();
  await feed(warm, 'http://127.0.0.1:8123/b.mp3');
  final warmMs = await waitForFile('b_');
  print('pre-warmed fetch: $warmMs ms (total ${sw.elapsedMilliseconds})');
  await warm.exitCode;
}
