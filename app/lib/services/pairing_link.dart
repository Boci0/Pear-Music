/// Parsing/encoding for the pairing QR payload.
///
/// The host QR encodes the 6-char pairing code:
///
///   pearmusic://pair/ABC123
///
/// The old format could also carry a server hint
/// (`pearmusic://pair/ABC123?server=…`) — `parse` still understands it so
/// previously-printed QRs keep working, but the app no longer encodes it:
/// discovery (ServerDiscovery) finds the host automatically instead.
class PairingLink {
  const PairingLink({required this.code, this.server});

  final String code;

  /// Only present in the legacy QR format; ignored by the current flow.
  final String? server;

  static const String prefix = 'pearmusic://pair/';
  // Client-side lenient check (the server enforces the strict alphabet).
  static final RegExp _codeRe = RegExp(r'^[A-Z0-9]{6}$');

  /// Builds the QR payload: `pearmusic://pair/<CODE>?server=<WS_URL>`
  static String encode(String code, {String? server}) {
    final c = code.trim().toUpperCase();
    if (server != null && server.isNotEmpty) {
      return '$prefix$c?server=${Uri.encodeQueryComponent(server)}';
    }
    return '$prefix$c';
  }

  /// Parses a scanned value (raw code or deep link). Returns null if it isn't
  /// a valid pairing link.
  static PairingLink? parse(String raw) {
    final trimmed = raw.trim();
    String codePart = trimmed;
    if (trimmed.startsWith(prefix)) {
      codePart = trimmed.substring(prefix.length);
    }
    String? server;
    final q = codePart.indexOf('?');
    if (q >= 0) {
      final query = codePart.substring(q + 1);
      codePart = codePart.substring(0, q);
      server = Uri.splitQueryString(query)['server'];
    }
    final code = codePart.trim().toUpperCase();
    if (code.length != 6 || !_codeRe.hasMatch(code)) return null;
    return PairingLink(
      code: code,
      server: (server == null || server.isEmpty) ? null : server,
    );
  }
}
