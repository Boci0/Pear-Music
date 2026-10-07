import 'dart:convert';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart';

/// Ed25519 public key (base64, 32 raw bytes) that signs the yt-dlp mirror
/// manifest. The private half lives only in the release pipeline's
/// `YTDLP_SIGNING_KEY` secret. To rotate it, ship an app update with the new
/// key before switching the secret.
const String kYtDlpManifestPublicKey =
    'NqJdMxlcOP9yzfscbjfcSUhonYTYBph7b2tDfdpUoJo=';

/// One downloadable file listed in the manifest.
class YtDlpAsset {
  const YtDlpAsset({required this.sha256, required this.size});
  final String sha256;
  final int size;
}

/// The signed description of a mirrored yt-dlp release (`manifest.json`, with
/// its detached signature in `manifest.json.sig`).
///
/// Trust comes from the signature, not from the host that served the files, so
/// any mirror can be used without being trusted.
class YtDlpManifest {
  const YtDlpManifest({
    required this.ytDlpVersion,
    required this.assets,
    required this.sources,
  });

  final String ytDlpVersion;
  final Map<String, YtDlpAsset> assets;

  /// Extra download bases the publisher wants clients to try.
  final List<String> sources;

  /// Parses [manifestBytes] only if [signature] is a valid signature over those
  /// exact bytes. Returns null for a bad signature or a malformed manifest.
  static YtDlpManifest? parseVerified(
    Uint8List manifestBytes,
    Uint8List signature, {
    String publicKeyBase64 = kYtDlpManifestPublicKey,
  }) {
    try {
      final key = base64.decode(publicKeyBase64);
      if (key.length != 32 || signature.length != 64) return null;
      if (!ed.verify(ed.PublicKey(key), manifestBytes, signature)) return null;
      final json = jsonDecode(utf8.decode(manifestBytes));
      if (json is! Map<String, dynamic> || json['schema'] != 1) return null;
      final version = json['ytdlp_version'];
      final rawAssets = json['assets'];
      if (version is! String || version.isEmpty || rawAssets is! Map) {
        return null;
      }
      final assets = <String, YtDlpAsset>{};
      for (final e in rawAssets.entries) {
        final v = e.value;
        if (v is! Map) continue;
        final hash = v['sha256'];
        final size = v['size'];
        if (hash is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
          continue;
        }
        assets['${e.key}'] = YtDlpAsset(
          sha256: hash.toLowerCase(),
          size: size is int ? size : 0,
        );
      }
      final sources = <String>[
        for (final s in (json['sources'] as List? ?? const []))
          if (s is String && s.startsWith('https://')) s,
      ];
      return YtDlpManifest(
        ytDlpVersion: version,
        assets: assets,
        sources: sources,
      );
    } catch (e) {
      debugPrint('[pearmusic] yt-dlp manifest rejected: $e');
      return null;
    }
  }

  /// True when yt-dlp version [candidate] is strictly newer than [current].
  /// Versions are dotted numbers such as `2026.08.19` or `2026.08.19.123456`;
  /// anything unparseable is never treated as newer.
  static bool isNewerVersion(String candidate, String current) {
    List<int>? parse(String v) {
      final parts = v.trim().split('.');
      final out = <int>[];
      for (final p in parts) {
        final n = int.tryParse(p);
        if (n == null) return null;
        out.add(n);
      }
      return out.isEmpty ? null : out;
    }

    final a = parse(candidate);
    final b = parse(current);
    if (a == null || b == null) return false;
    for (var i = 0; i < a.length || i < b.length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}
