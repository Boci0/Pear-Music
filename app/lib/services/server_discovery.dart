import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A nearby device that runs a Pear Music signaling server, discovered on the
/// local network (mirrors how LocalSend finds devices).
class DiscoveredServer {
  const DiscoveredServer({
    required this.name,
    required this.url,
    this.deviceId,
  });

  final String name;

  /// `ws://<ip>:<port>` that this device's embedded server listens on.
  final String url;
  final String? deviceId;

  @override
  String toString() => '$name ($url)';
}

/// LAN discovery for embedded Pear Music servers — LocalSend-style.
///
/// Finds every Pear Music host on the local network in two ways:
///   1. UDP multicast: probe the multicast group; every embedded server
///      replies (best-effort — ignored if the network/firewall drops it).
///   2. Subnet scan over HTTP: hit `GET /discover` on every host of each local
///      /24 subnet (LocalSend's fallback for networks that block multicast;
///      this is the reliable path since it rides the existing TCP :8080).
class ServerDiscovery {
  ServerDiscovery._();

  static const int port = 8080;
  static const String multicastGroup = '224.0.0.173'; // in 224.0.0.0/24 (Android-friendly)

  static const Duration _httpTimeout = Duration(milliseconds: 400);
  static const Duration _multicastWait = Duration(seconds: 2);
  static const int _scanConcurrency = 50;

  /// Discovers nearby servers, deduplicated by URL. Never throws.
  ///
  /// Multicast is tried first. The subnet scan (up to 254 concurrent HTTP
  /// connection attempts) only runs as a fallback when multicast finds nothing
  /// — on a typical home LAN multicast works, so the scan is skipped entirely.
  static Future<List<DiscoveredServer>> discover() async {
    final results = <String, DiscoveredServer>{};
    await _discoverViaMulticast(results);
    if (results.isEmpty) {
      await _discoverViaSubnetScan(results);
    }
    return results.values.toList();
  }

  static Future<void> _discoverViaMulticast(
    Map<String, DiscoveredServer> out,
  ) async {
    RawDatagramSocket? socket;
    try {
      final bound = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket = bound;
      final probe = utf8.encode(jsonEncode({'type': 'peerm_probe'}));
      final group = InternetAddress(multicastGroup);
      for (var i = 0; i < 3; i++) {
        bound.send(probe, group, port);
        await Future.delayed(const Duration(milliseconds: 100));
      }
      bound.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = bound.receive();
        if (dg == null) return;
        final server = _parseHello(dg.data);
        if (server != null) out[server.url] = server;
      });
      final deadline = DateTime.now().add(_multicastWait);
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } catch (_) {
      // multicast unavailable — subnet scan still runs
    } finally {
      try {
        socket?.close();
      } catch (_) {}
    }
  }

  static Future<void> _discoverViaSubnetScan(
    Map<String, DiscoveredServer> out,
  ) async {
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
    if (localIps.isEmpty) return;

    final client = HttpClient()
      ..connectionTimeout = _httpTimeout
      ..autoUncompress = false;
    final semaphore = _Semaphore(_scanConcurrency);
    final tasks = <Future<void>>[];
    for (final localIp in localIps) {
      final parts = localIp.split('.');
      if (parts.length != 4) continue;
      final prefix = '${parts[0]}.${parts[1]}.${parts[2]}.';
      final ownLast = int.tryParse(parts[3]) ?? -1;
      for (var last = 1; last < 255; last++) {
        if (last == ownLast) continue; // don't probe ourselves
        final host = '$prefix$last';
        tasks.add(semaphore.run(() => _probeHttp(client, host, out)));
      }
    }
    try {
      await Future.wait(tasks);
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _probeHttp(
    HttpClient client,
    String host,
    Map<String, DiscoveredServer> out,
  ) async {
    try {
      final req = await client.getUrl(Uri.parse('http://$host:$port/discover'));
      final res = await req.close();
      if (res.statusCode != HttpStatus.ok) return;
      final body = await res.transform(utf8.decoder).join();
      final server = _parseHello(utf8.encode(body));
      if (server != null) out[server.url] = server;
    } catch (_) {
      // host not reachable / not a Pear Music device
    }
  }

  /// Parses a `peerm_hello` JSON payload into a [DiscoveredServer], or null.
  static DiscoveredServer? _parseHello(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['type'] != 'peerm_hello') return null;
      final url = decoded['url'] as String?;
      if (url == null || url.isEmpty) return null;
      return DiscoveredServer(
        name: (decoded['name'] as String?)?.trim().isNotEmpty == true
            ? (decoded['name'] as String).trim()
            : 'Pear Music device',
        url: url,
        deviceId: decoded['deviceId'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Tiny async semaphore to bound subnet-scan concurrency.
class _Semaphore {
  _Semaphore(this.max);
  final int max;
  int _active = 0;
  final List<Completer<void>> _waiters = [];

  Future<void> _acquire() async {
    if (_active < max) {
      _active++;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    await c.future;
    _active++;
  }

  void _release() {
    _active--;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }

  Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }
}
