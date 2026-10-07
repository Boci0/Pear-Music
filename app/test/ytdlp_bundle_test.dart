import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/ytdlp_bundle.dart';

void main() {
  final pair = ed.generateKey();
  final keys = [base64.encode(pair.publicKey.bytes)];
  final payload = Uint8List.fromList(List.generate(5000, (i) => i % 251));

  Uint8List manifestFor(Uint8List bin, {int? size, String name = 'yt-dlp.exe'}) =>
      Uint8List.fromList(utf8.encode(jsonEncode({
        'schema': 1,
        'ytdlp_version': '2026.08.19',
        'assets': {
          name: {
            'sha256': sha256.convert(bin).toString(),
            'size': size ?? bin.length,
          },
        },
        'sources': <String>[],
      })));

  String sign(Uint8List m) => base64.encode(ed.sign(pair.privateKey, m));

  Uint8List bundle({
    Uint8List? bin,
    Uint8List? manifest,
    String? sig,
    String name = 'yt-dlp.exe',
  }) {
    final b = bin ?? payload;
    final m = manifest ?? manifestFor(payload);
    return YtDlpBundle.pack(
      manifestBytes: m,
      signatureText: sig ?? sign(m),
      assetName: name,
      payload: b,
    );
  }

  test('a packed bundle round-trips and verifies', () {
    final parsed = YtDlpBundle.parse(bundle(), publicKeysBase64: keys);
    expect(parsed, isNotNull);
    expect(parsed!.assetName, 'yt-dlp.exe');
    expect(parsed.ytDlpVersion, '2026.08.19');
    expect(parsed.payload, payload);
  });

  test('a tampered binary is rejected', () {
    final bad = Uint8List.fromList(payload)..[100] ^= 0xff;
    expect(
      YtDlpBundle.parse(bundle(bin: bad), publicKeysBase64: keys),
      isNull,
    );
  });

  test('a tampered manifest is rejected', () {
    final m = manifestFor(payload);
    final sig = sign(m);
    final other = manifestFor(Uint8List.fromList([1, 2, 3]));
    expect(
      YtDlpBundle.parse(bundle(manifest: other, sig: sig), publicKeysBase64: keys),
      isNull,
    );
  });

  test('a signature from another key is rejected', () {
    final other = ed.generateKey();
    final m = manifestFor(payload);
    final sig = base64.encode(ed.sign(other.privateKey, m));
    expect(
      YtDlpBundle.parse(bundle(manifest: m, sig: sig), publicKeysBase64: keys),
      isNull,
    );
  });

  test('the asset name must be listed in the manifest', () {
    expect(
      YtDlpBundle.parse(bundle(name: 'yt-dlp_linux'), publicKeysBase64: keys),
      isNull,
    );
  });

  test('a wrong listed size is rejected', () {
    final m = manifestFor(payload, size: payload.length + 1);
    expect(
      YtDlpBundle.parse(bundle(manifest: m), publicKeysBase64: keys),
      isNull,
    );
  });

  test('garbage and truncated files never throw', () {
    expect(YtDlpBundle.parse(Uint8List(0), publicKeysBase64: keys), isNull);
    expect(
      YtDlpBundle.parse(Uint8List.fromList(utf8.encode('hello world')),
          publicKeysBase64: keys),
      isNull,
    );
    final good = bundle();
    for (final cut in [8, 20, 200, good.length - 1]) {
      expect(
        YtDlpBundle.parse(good.sublist(0, cut), publicKeysBase64: keys),
        isNull,
        reason: 'cut at $cut',
      );
    }
  });
}
