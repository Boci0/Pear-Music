/// Parsing/encoding for the pairing QR payload.
///
/// The QR encodes the 6-character pairing code along with the host address and port:
///
///   pearmusic://pair/ABC123?host=192.168.1.50&port=8080
///
/// Backward-compatible with plain codes and legacy server query URLs.
class PairingLink {
  const PairingLink({
    required this.code,
    this.host,
    this.port,
    this.server,
  });

  final String code;
  final String? host;
  final int? port;

  /// Legacy WebSocket or HTTP server URL hint.
  final String? server;

  static const String prefix = 'pearmusic://pair/';
  static final RegExp _codeRe = RegExp(r'^[A-Z0-9]{6}$');

  /// Direct HTTP URL to post pairing credentials to.
  String? get httpPairUrl {
    if (host != null && host!.isNotEmpty) {
      final p = port ?? 8080;
      return 'http://$host:$p/api/pair';
    }
    if (server != null && server!.isNotEmpty) {
      var s = server!;
      if (s.startsWith('ws://')) s = 'http://${s.substring(5)}';
      if (s.startsWith('wss://')) s = 'https://${s.substring(6)}';
      if (!s.startsWith('http://') && !s.startsWith('https://')) {
        s = 'http://$s';
      }
      final uri = Uri.tryParse(s);
      if (uri != null) {
        return '${uri.scheme}://${uri.host}:${uri.port}/api/pair';
      }
    }
    return null;
  }

  /// Builds the QR payload.
  static String encode(
    String code, {
    String? host,
    int? port,
    String? server,
  }) {
    final c = code.trim().toUpperCase();
    final params = <String, String>{};
    if (host != null && host.isNotEmpty) {
      params['host'] = host;
    }
    if (port != null && port > 0) {
      params['port'] = port.toString();
    }
    if (server != null && server.isNotEmpty) {
      params['server'] = server;
    }
    if (params.isEmpty) return '$prefix$c';
    final query = Uri(queryParameters: params).query;
    return '$prefix$c?$query';
  }

  /// Parses a scanned value (raw code or deep link). Returns null if invalid.
  static PairingLink? parse(String raw) {
    final trimmed = raw.trim();
    String codePart = trimmed;
    if (trimmed.startsWith(prefix)) {
      codePart = trimmed.substring(prefix.length);
    }
    String? host;
    int? port;
    String? server;
    final q = codePart.indexOf('?');
    if (q >= 0) {
      final query = codePart.substring(q + 1);
      codePart = codePart.substring(0, q);
      final params = Uri.splitQueryString(query);
      host = params['host'];
      if (params['port'] != null) {
        port = int.tryParse(params['port']!);
      }
      server = params['server'];
    }
    final code = codePart.trim().toUpperCase();
    if (code.length != 6 || !_codeRe.hasMatch(code)) return null;
    return PairingLink(
      code: code,
      host: host,
      port: port,
      server: (server == null || server.isEmpty) ? null : server,
    );
  }
}
