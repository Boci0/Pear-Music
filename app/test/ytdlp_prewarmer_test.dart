import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/ytdlp_prewarmer.dart';

void main() {
  tearDown(() {
    YtDlpPrewarmer.setEnabledForTesting(null);
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
  });
}
