// Local file server for the yt-dlp worker benchmark (no YouTube involved).
// Usage: dart run tool/dart_bench_server.dart [port]
import 'dart:io';

Future<void> main(List<String> argv) async {
  final port = argv.isNotEmpty ? int.parse(argv.first) : 8123;
  final dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}peerm_bench_http')
    ..createSync(recursive: true);
  final sep = Platform.pathSeparator;
  final a = File('${dir.path}${sep}a.mp3');
  final b = File('${dir.path}${sep}b.mp3');
  if (!a.existsSync() || a.lengthSync() != 1048576) {
    a.writeAsBytesSync(List<int>.generate(1048576, (i) => i & 0xff));
  }
  if (!b.existsSync() || b.lengthSync() != 2097152) {
    b.writeAsBytesSync(List<int>.generate(2097152, (i) => (i * 7) & 0xff));
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('serving ${dir.path} on http://127.0.0.1:$port/');
  await for (final request in server) {
    final segments = request.uri.pathSegments;
    final name = segments.isEmpty ? '' : segments.last;
    final file = File('${dir.path}${sep}$name');
    if (file.existsSync()) {
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.add(file.readAsBytesSync());
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }
}
