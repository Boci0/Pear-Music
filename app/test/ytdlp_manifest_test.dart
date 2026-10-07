import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/ytdlp_manifest.dart';

void main() {
  final pair = ed.generateKey();
  final pub = base64.encode(pair.publicKey.bytes);
  final hash = 'ab' * 32;

  Uint8List manifest({int schema = 1, String version = '2026.08.19'}) =>
      Uint8List.fromList(utf8.encode(jsonEncode({
        'schema': schema,
        'ytdlp_version': version,
        'assets': {
          'yt-dlp.exe': {'sha256': hash.toUpperCase(), 'size': 123},
          'bad': {'sha256': 'nothex', 'size': 1},
        },
        'sources': ['https://one.example/x', 'http://insecure.example'],
      })));

  Uint8List sign(Uint8List m) => ed.sign(pair.privateKey, m);

  group('YtDlpManifest.parseVerified', () {
    test('accepts a correctly signed manifest', () {
      final m = manifest();
      final parsed =
          YtDlpManifest.parseVerified(m, sign(m), publicKeyBase64: pub);
      expect(parsed, isNotNull);
      expect(parsed!.ytDlpVersion, '2026.08.19');
      expect(parsed.assets.keys, ['yt-dlp.exe']);
      expect(parsed.assets['yt-dlp.exe']!.sha256, hash);
      expect(parsed.sources, ['https://one.example/x']);
    });

    test('rejects a tampered manifest', () {
      final m = manifest();
      final sig = sign(m);
      final tampered = manifest(version: '2099.01.01');
      expect(
        YtDlpManifest.parseVerified(tampered, sig, publicKeyBase64: pub),
        isNull,
      );
    });

    test('rejects a signature from another key', () {
      final other = ed.generateKey();
      final m = manifest();
      final sig = ed.sign(other.privateKey, m);
      expect(YtDlpManifest.parseVerified(m, sig, publicKeyBase64: pub), isNull);
    });

    test('rejects the embedded key when signed by a test key', () {
      final m = manifest();
      expect(YtDlpManifest.parseVerified(m, sign(m)), isNull);
    });

    test('rejects an unknown schema and malformed signatures', () {
      final m = manifest(schema: 2);
      expect(
        YtDlpManifest.parseVerified(m, sign(m), publicKeyBase64: pub),
        isNull,
      );
      final ok = manifest();
      expect(
        YtDlpManifest.parseVerified(ok, Uint8List(10), publicKeyBase64: pub),
        isNull,
      );
    });
  });

  group('YtDlpManifest.isNewerVersion', () {
    test('compares dotted dates numerically', () {
      expect(YtDlpManifest.isNewerVersion('2026.09.01', '2026.08.19'), isTrue);
      expect(YtDlpManifest.isNewerVersion('2026.08.19', '2026.08.19'), isFalse);
      expect(YtDlpManifest.isNewerVersion('2026.08.19', '2026.09.01'), isFalse);
      expect(YtDlpManifest.isNewerVersion('2026.8.20', '2026.08.19'), isTrue);
    });

    test('handles a trailing build segment', () {
      expect(
        YtDlpManifest.isNewerVersion('2026.08.19.123456', '2026.08.19'),
        isTrue,
      );
      expect(
        YtDlpManifest.isNewerVersion('2026.08.19', '2026.08.19.123456'),
        isFalse,
      );
    });

    test('never treats unparseable versions as newer', () {
      expect(YtDlpManifest.isNewerVersion('nightly', '2026.08.19'), isFalse);
      expect(YtDlpManifest.isNewerVersion('2026.08.19', ''), isFalse);
    });
  });
}
