import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:peerm_app/services/youtube_service.dart';
import 'package:peerm_app/services/ytdlp_bundle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sandbox = Directory.systemTemp.createTempSync('peerm_ytdlp_import_');
  final pair = ed.generateKey();
  final keys = [base64.encode(pair.publicKey.bytes)];
  final assetName = Platform.isWindows
      ? 'yt-dlp.exe'
      : (Platform.isMacOS ? 'yt-dlp_macos' : 'yt-dlp_linux');
  final binary = Uint8List.fromList(List.generate(4000, (i) => (i * 7) % 256));
  final localBin = File(p.join(sandbox.path, 'bin', assetName));

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => sandbox.path);
  });
  tearDownAll(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  File writeBundle(String name, {String? asset, ed.KeyPair? signer}) {
    final manifest = Uint8List.fromList(utf8.encode(jsonEncode({
      'schema': 1,
      'ytdlp_version': '2026.08.19',
      'assets': {
        asset ?? assetName: {
          'sha256': sha256.convert(binary).toString(),
          'size': binary.length,
        },
      },
      'sources': <String>[],
    })));
    final sig = base64.encode(ed.sign((signer ?? pair).privateKey, manifest));
    final file = File(p.join(sandbox.path, name));
    file.writeAsBytesSync(YtDlpBundle.pack(
      manifestBytes: manifest,
      signatureText: sig,
      assetName: asset ?? assetName,
      payload: binary,
    ));
    return file;
  }

  test('a bundle signed by an untrusted key installs nothing', () async {
    final file = writeBundle('evil.pmyd', signer: ed.generateKey());
    final result = await YoutubeService.importYtDlpBundle(file, trustedKeys: keys);
    expect(result.status, YtDlpUpdateStatus.invalid);
    expect(localBin.existsSync(), isFalse);
  });

  test('a bundle for another platform is refused', () async {
    final other = Platform.isWindows ? 'yt-dlp_linux' : 'yt-dlp.exe';
    final file = writeBundle('other.pmyd', asset: other);
    final result = await YoutubeService.importYtDlpBundle(file, trustedKeys: keys);
    expect(result.status, YtDlpUpdateStatus.wrongPlatform);
    expect(localBin.existsSync(), isFalse);
  });

  test('a valid bundle installs the binary and leaves no temp file', () async {
    final file = writeBundle('good.pmyd');
    final result = await YoutubeService.importYtDlpBundle(file, trustedKeys: keys);
    expect(result.status, YtDlpUpdateStatus.updated);
    expect(result.version, '2026.08.19');
    expect(localBin.readAsBytesSync(), binary);
    expect(File('${localBin.path}.new').existsSync(), isFalse);
  });

  test('an installed binary that will not run is replaced, not kept', () async {
    // The fake binary from the previous test cannot report a version.
    localBin.writeAsBytesSync(List.filled(64, 1));
    final file = writeBundle('replace.pmyd');
    final result = await YoutubeService.importYtDlpBundle(file, trustedKeys: keys);
    expect(result.status, YtDlpUpdateStatus.updated);
    expect(localBin.readAsBytesSync(), binary);
  });

  test('garbage is rejected without touching the installed binary', () async {
    final junk = File(p.join(sandbox.path, 'junk.pmyd'))
      ..writeAsBytesSync([1, 2, 3, 4]);
    final before = localBin.readAsBytesSync();
    final result = await YoutubeService.importYtDlpBundle(junk, trustedKeys: keys);
    expect(result.status, YtDlpUpdateStatus.invalid);
    expect(localBin.readAsBytesSync(), before);
  });
}
