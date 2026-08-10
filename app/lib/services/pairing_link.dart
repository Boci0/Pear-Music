/// Parsing/encoding for the pairing QR payload.
///
/// The host QR encodes a deep link that carries BOTH the 6-char pairing code
/// AND (when the host is running its embedded server) the server address the
/// joiner must connect to, so scanning it switches the joiner onto the right
/// server and pairs it in one step:
///
///   pearmusic://pair/ABC123
///   pearmusic://pair/ABC123?server=ws%3A%2F%2F192.168.1.5%3A8080
///
/// A bare 6-char code (no scheme/query) is also accepted, matching the old
/// behaviour for codes typed/printed without the server hint.
class PairingLink {
  const PairingLink({required this.code, this.server});

  final String code;
  final String? server;

  static const String prefix = 'pearmusic://pair/';
  // Client-side lenient check (the server enforces the strict alphabet).
  static final RegExp _codeRe = RegExp(r'^[A-Z0-9]{6}$');

  /// Builds the QR payload for [code], optionally appending the host server.
  static String encode(String code, {String? server}) {
    final c = code.trim().toUpperCase();
    if (server == null || server.isEmpty) return '$prefix$c';
    return '$prefix$c?server=${Uri.encodeComponent(server)}';
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
