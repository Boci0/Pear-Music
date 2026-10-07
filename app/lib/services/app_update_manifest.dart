import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'signing_keys.dart';

/// One downloadable file of an app release: its expected SHA-256 and every
/// place it can be fetched from, best first.
class AppUpdateAsset {
  const AppUpdateAsset({
    required this.sha256,
    required this.size,
    required this.urls,
  });

  final String sha256;
  final int size;
  final List<String> urls;
}

/// The signed description of an app release (`app-update.json`, with its
/// detached signature in `app-update.json.sig`).
///
/// Trust comes from the signature, not from the host that served the file, so
/// the same manifest can be fetched from any mirror, and the files it lists can
/// come from any host that serves the right bytes.
class AppUpdateManifest {
  const AppUpdateManifest({
    required this.version,
    required this.notes,
    required this.page,
    required this.assets,
  });

  final String version;
  final String notes;

  /// Human-readable release page, opened when an update cannot be applied
  /// in place.
  final String page;
  final Map<String, AppUpdateAsset> assets;

  /// Parses [manifestBytes] only if [signature] is a valid signature over those
  /// exact bytes. Returns null for a bad signature or a malformed manifest.
  ///
  /// Each asset's URLs are kept only if they are https and end in the asset's
  /// own name, which is how downloads are matched to their expected hash.
  static AppUpdateManifest? parseVerified(
    Uint8List manifestBytes,
    Uint8List signature, {
    List<String> publicKeysBase64 = kSigningPublicKeys,
  }) {
    try {
      if (!verifySignature(manifestBytes, signature,
          publicKeysBase64: publicKeysBase64)) {
        return null;
      }
      final json = jsonDecode(utf8.decode(manifestBytes));
      if (json is! Map<String, dynamic> ||
          json['schema'] != 1 ||
          json['kind'] != 'app-update') {
        return null;
      }
      final version = json['version'];
      final rawAssets = json['assets'];
      if (version is! String ||
          !RegExp(r'^\d+(\.\d+){1,3}$').hasMatch(version) ||
          rawAssets is! Map) {
        return null;
      }
      final assets = <String, AppUpdateAsset>{};
      for (final e in rawAssets.entries) {
        final name = '${e.key}';
        final v = e.value;
        if (v is! Map || name.isEmpty || name.contains('/') || name.contains('\\')) {
          continue;
        }
        final hash = v['sha256'];
        if (hash is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
          continue;
        }
        final urls = <String>[
          for (final u in (v['urls'] as List? ?? const []))
            if (u is String && u.startsWith('https://') && u.endsWith('/$name')) u,
        ];
        if (urls.isEmpty) continue;
        final size = v['size'];
        assets[name] = AppUpdateAsset(
          sha256: hash.toLowerCase(),
          size: size is int ? size : 0,
          urls: urls,
        );
      }
      if (assets.isEmpty) return null;
      final notes = json['notes'];
      final page = json['page'];
      return AppUpdateManifest(
        version: version,
        notes: notes is String && notes.trim().isNotEmpty
            ? notes.trim()
            : 'No release notes provided.',
        page: page is String && page.startsWith('https://')
            ? page
            : 'https://github.com/Boci0/Pear-Music/releases',
        assets: assets,
      );
    } catch (e) {
      debugPrint('[pearmusic] app update manifest rejected: $e');
      return null;
    }
  }
}
