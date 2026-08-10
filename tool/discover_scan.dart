// Standalone diagnostic: LAN discovery subnet scan (mirrors ServerDiscovery).
// Finds every Pear Music embedded server on the local /24 subnet(s) by
// GETting http://<ip>:8080/discover. Pure dart:io — run with:
//   dart run tool/discover_scan.dart
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 400)
    ..autoUncompress = false;

  final localIps = <String>{};
  try {
    final ifaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final iface in ifaces) {
      for (final addr in iface.addresses) {
        localIps.add(addr.address);
      }
    }
  } catch (_) {}
  print('local IPv4s: $localIps');

  final tasks = <Future<void>>[];
  var active = 0;
  const maxConcurrent = 40;

  Future<void> probe(String host) async {
    try {
      final req =
          await client.getUrl(Uri.parse('http://$host:8080/discover'));
      final res = await req.close();
      if (res.statusCode != 200) return;
      final body = await res.transform(utf8.decoder).join();
      final d = jsonDecode(body) as Map<String, dynamic>;
      if (d['type'] == 'peerm_hello') {
        print('FOUND  ${d['name']}  ->  ${d['url']}');
      }
    } catch (_) {
      // not a Pear Music host
    }
  }

  Future<void> run(Future<void> Function() task) async {
    active++;
    try {
      await task();
    } finally {
      active--;
    }
  }

  for (final localIp in localIps) {
    final parts = localIp.split('.');
    if (parts.length != 4) continue;
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}.';
    final ownLast = int.tryParse(parts[3]) ?? -1;
    for (var last = 1; last < 255; last++) {
      if (last == ownLast) continue;
      final host = '$prefix$last';
      tasks.add(run(() => probe(host)));
      while (active >= maxConcurrent) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }
  }
  await Future.wait(tasks);
  client.close(force: true);
  print('Scan complete.');
}
