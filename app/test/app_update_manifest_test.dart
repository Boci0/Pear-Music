import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/app_update_manifest.dart';
import 'package:peerm_app/services/signing_keys.dart';
import 'package:peerm_app/services/update_service.dart';

void main() {
  final pair = ed.generateKey();
  final keys = [base64.encode(pair.publicKey.bytes)];
  final hash = 'cd' * 32;
  const gh = 'https://github.com/Boci0/Pear-Music/releases/download/v4.3.5';
  const mirror =
      'https://github.com/Boci0/pm-resolver-mirror/releases/download/app-update';

  Map<String, dynamic> body({
    String kind = 'app-update',
    int schema = 1,
    String version = '4.3.5',
    Map<String, dynamic>? assets,
  }) =>
      {
        'schema': schema,
        'kind': kind,
        'version': version,
        'notes': 'Fixes things',
        'page': 'https://github.com/Boci0/Pear-Music/releases/tag/v4.3.5',
        'assets': assets ??
            {
              'PearMusic-Windows-x64.zip': {
                'sha256': hash.toUpperCase(),
                'size': 100,
                'urls': [
                  '$gh/PearMusic-Windows-x64.zip',
                  '$mirror/PearMusic-Windows-x64.zip',
                ],
              },
              'PearMusic-Android-arm64.apk': {
                'sha256': hash,
                'size': 90,
                'urls': ['$gh/PearMusic-Android-arm64.apk'],
              },
              'PearMusic-Android-armv7.apk': {
                'sha256': hash,
                'size': 80,
                'urls': ['$gh/PearMusic-Android-armv7.apk'],
              },
              'PearMusic-Windows-Setup.exe': {
                'sha256': hash,
                'size': 70,
                'urls': ['$gh/PearMusic-Windows-Setup.exe'],
              },
            },
      };

  Uint8List bytes(Map<String, dynamic> m) =>
      Uint8List.fromList(utf8.encode(jsonEncode(m)));
  Uint8List sign(Uint8List b) => ed.sign(pair.privateKey, b);

  AppUpdateManifest? parse(Map<String, dynamic> m, {Uint8List? sig}) {
    final b = bytes(m);
    return AppUpdateManifest.parseVerified(
      b,
      sig ?? sign(b),
      publicKeysBase64: keys,
    );
  }

  group('AppUpdateManifest.parseVerified', () {
    test('accepts a correctly signed manifest', () {
      final m = parse(body())!;
      expect(m.version, '4.3.5');
      expect(m.notes, 'Fixes things');
      expect(m.assets.keys, hasLength(4));
      final zip = m.assets['PearMusic-Windows-x64.zip']!;
      expect(zip.sha256, hash);
      expect(zip.urls, hasLength(2));
    });

    test('rejects a tampered manifest and a foreign signature', () {
      final good = bytes(body());
      final sig = sign(good);
      expect(
        AppUpdateManifest.parseVerified(
          bytes(body(version: '9.9.9')),
          sig,
          publicKeysBase64: keys,
        ),
        isNull,
      );
      final other = ed.generateKey();
      expect(parse(body(), sig: ed.sign(other.privateKey, good)), isNull);
    });

    test('rejects the embedded keys when signed by a test key', () {
      final b = bytes(body());
      expect(AppUpdateManifest.parseVerified(b, sign(b)), isNull);
      expect(kSigningPublicKeys.length, 2);
    });

    test('a yt-dlp manifest cannot be passed off as an app update', () {
      final ytdlp = {
        'schema': 1,
        'ytdlp_version': '2026.08.19',
        'assets': {
          'yt-dlp.exe': {'sha256': hash, 'size': 1},
        },
      };
      expect(parse(ytdlp), isNull);
      expect(parse(body(kind: 'yt-dlp')), isNull);
    });

    test('rejects an unknown schema, a bad version and an empty asset list', () {
      expect(parse(body(schema: 2)), isNull);
      expect(parse(body(version: 'latest')), isNull);
      expect(parse(body(assets: {})), isNull);
    });

    test('drops unsafe assets and urls', () {
      final m = parse(body(assets: {
        'good.zip': {
          'sha256': hash,
          'urls': [
            'http://insecure.example/good.zip',
            'https://host.example/other-name.zip',
            'https://host.example/good.zip',
          ],
        },
        '../evil.zip': {
          'sha256': hash,
          'urls': ['https://host.example/../evil.zip'],
        },
        'badhash.zip': {
          'sha256': 'zz',
          'urls': ['https://host.example/badhash.zip'],
        },
        'nourls.zip': {'sha256': hash, 'urls': <String>[]},
      }))!;
      expect(m.assets.keys, ['good.zip']);
      expect(m.assets['good.zip']!.urls, ['https://host.example/good.zip']);
    });
  });

  group('UpdateService.buildInfoFromManifest', () {
    AppUpdateManifest manifest() => parse(body())!;

    test('a verified manifest becomes a verified update with every host', () {
      final info = UpdateService.buildInfoFromManifest(
        manifest(),
        currentVersion: '4.3.4',
        abis: const ['arm64-v8a'],
      );
      expect(info.verified, isTrue);
      expect(info.hasUpdate, isTrue);
      expect(info.latestVersion, '4.3.5');
      expect(info.zipUrl, '$gh/PearMusic-Windows-x64.zip');
      expect(info.setupUrl, '$gh/PearMusic-Windows-Setup.exe');
      expect(info.apkUrl, '$gh/PearMusic-Android-arm64.apk');
      expect(info.sha256ByName['PearMusic-Windows-x64.zip'], hash);
      expect(
        info.urlsByName['PearMusic-Windows-x64.zip'],
        ['$gh/PearMusic-Windows-x64.zip', '$mirror/PearMusic-Windows-x64.zip'],
      );
    });

    test('the same or an older version is not an update', () {
      for (final current in ['4.3.5', '4.4.0']) {
        expect(
          UpdateService.buildInfoFromManifest(manifest(), currentVersion: current)
              .hasUpdate,
          isFalse,
          reason: current,
        );
      }
    });

    test('an unverified legacy update is never marked verified', () {
      const legacy = UpdateInfo(
        hasUpdate: true,
        currentVersion: '4.3.4',
        latestVersion: '4.3.5',
        releaseNotes: '',
        htmlUrl: 'https://github.com/Boci0/Pear-Music/releases',
      );
      expect(legacy.verified, isFalse);
      expect(legacy.urlsByName, isEmpty);
    });
  });

  group('UpdateService.selectApkUrl', () {
    test('prefers the APK that matches the device', () {
      expect(
        UpdateService.selectApkUrl(
          abis: const ['armeabi-v7a'],
          arm64: 'a64',
          armv7: 'a32',
        ),
        'a32',
      );
      expect(
        UpdateService.selectApkUrl(
          abis: const ['arm64-v8a', 'armeabi-v7a'],
          arm64: 'a64',
          armv7: 'a32',
        ),
        'a64',
      );
    });

    test('falls back to whatever the release has', () {
      expect(UpdateService.selectApkUrl(abis: const [], armv7: 'a32'), 'a32');
      expect(UpdateService.selectApkUrl(abis: const []), isNull);
    });
  });

  test('the update hosts are two different repositories', () {
    expect(UpdateService.manifestBases.toSet().length, 2);
    expect(
      UpdateService.manifestBases.every((b) => b.startsWith('https://')),
      isTrue,
    );
  });
}
