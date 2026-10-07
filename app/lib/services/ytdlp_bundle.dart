import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'ytdlp_manifest.dart';

/// A single-file, self-verifying copy of one yt-dlp build: the signed manifest,
/// its signature and the binary itself.
///
/// Bundles let the resolver travel by any route (USB stick, chat, a friend's
/// download) with no public host involved, because [parse] trusts the signature
/// and the hash, not where the file came from.
///
/// Layout (big-endian):
/// `PMYD1\n` | u32 manifestLen | manifest | u32 sigLen | base64 signature |
/// u16 nameLen | asset name | binary (the rest of the file)
class YtDlpBundle {
  const YtDlpBundle({
    required this.manifest,
    required this.manifestBytes,
    required this.signatureText,
    required this.assetName,
    required this.payload,
  });

  static const fileExtension = 'pmyd';
  static final _magic = ascii.encode('PMYD1\n');

  final YtDlpManifest manifest;
  final Uint8List manifestBytes;

  /// Base64 text of the manifest signature, exactly as published.
  final String signatureText;

  /// Which manifest asset [payload] is, for example `yt-dlp.exe`.
  final String assetName;
  final Uint8List payload;

  String get ytDlpVersion => manifest.ytDlpVersion;

  /// Builds a bundle file. The caller must already hold a verified manifest.
  static Uint8List pack({
    required Uint8List manifestBytes,
    required String signatureText,
    required String assetName,
    required Uint8List payload,
  }) {
    final sig = ascii.encode(signatureText.trim());
    final name = utf8.encode(assetName);
    final out = BytesBuilder(copy: false)..add(_magic);
    out.add(_u32(manifestBytes.length));
    out.add(manifestBytes);
    out.add(_u32(sig.length));
    out.add(sig);
    out.add(Uint8List(2)..buffer.asByteData().setUint16(0, name.length));
    out.add(name);
    out.add(payload);
    return out.takeBytes();
  }

  /// Returns the bundle only if the manifest signature is valid and the
  /// payload's SHA-256 (and size, when listed) matches the manifest entry for
  /// its asset. Anything else, including a malformed file, returns null.
  static YtDlpBundle? parse(
    Uint8List data, {
    List<String> publicKeysBase64 = kYtDlpManifestPublicKeys,
  }) {
    try {
      final view = ByteData.sublistView(data);
      if (data.length < _magic.length + 4 ||
          !listEquals(data.sublist(0, _magic.length), _magic)) {
        return null;
      }
      var pos = _magic.length;

      final manifestLen = view.getUint32(pos);
      pos += 4;
      if (manifestLen > (1 << 20) || pos + manifestLen + 4 > data.length) {
        return null;
      }
      final manifestBytes = Uint8List.sublistView(data, pos, pos + manifestLen);
      pos += manifestLen;

      final sigLen = view.getUint32(pos);
      pos += 4;
      if (sigLen > 256 || pos + sigLen + 2 > data.length) return null;
      final sigText = ascii.decode(data.sublist(pos, pos + sigLen)).trim();
      pos += sigLen;

      final nameLen = view.getUint16(pos);
      pos += 2;
      if (nameLen == 0 || nameLen > 64 || pos + nameLen > data.length) {
        return null;
      }
      final assetName = utf8.decode(data.sublist(pos, pos + nameLen));
      pos += nameLen;

      final manifest = YtDlpManifest.parseVerified(
        manifestBytes,
        Uint8List.fromList(base64.decode(sigText)),
        publicKeysBase64: publicKeysBase64,
      );
      final asset = manifest?.assets[assetName];
      if (manifest == null || asset == null) return null;

      final payload = Uint8List.sublistView(data, pos);
      if (asset.size > 0 && payload.length != asset.size) return null;
      if (sha256.convert(payload).toString() != asset.sha256) return null;

      return YtDlpBundle(
        manifest: manifest,
        manifestBytes: Uint8List.fromList(manifestBytes),
        signatureText: sigText,
        assetName: assetName,
        payload: payload,
      );
    } catch (_) {
      return null;
    }
  }

  static Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);
}
