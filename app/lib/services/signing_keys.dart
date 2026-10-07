import 'dart:convert';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart';

/// Ed25519 public keys (base64, 32 raw bytes) that may sign anything the app
/// trusts from the network: the yt-dlp mirror manifests and bundles, and the
/// app's own update manifests. The first signs day to day (its private half is
/// the pipeline's `YTDLP_SIGNING_KEY` secret). The second is a recovery key
/// whose private half stays offline: if the first is ever lost or leaked, sign
/// with the recovery key and ship an app update that replaces the first entry.
const List<String> kSigningPublicKeys = [
  'NqJdMxlcOP9yzfscbjfcSUhonYTYBph7b2tDfdpUoJo=',
  '1aAq5ADR6I5MoiFtEdwQMhFyHx/DPst8ImreGbyagBI=',
];

/// True when [signature] is a valid Ed25519 signature over [message] by any
/// of [publicKeysBase64].
bool verifySignature(
  Uint8List message,
  Uint8List signature, {
  List<String> publicKeysBase64 = kSigningPublicKeys,
}) {
  if (signature.length != 64) return false;
  for (final b64 in publicKeysBase64) {
    try {
      final key = base64.decode(b64);
      if (key.length == 32 &&
          ed.verify(ed.PublicKey(key), message, signature)) {
        return true;
      }
    } catch (_) {}
  }
  return false;
}
