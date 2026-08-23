import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/update_service.dart';
import 'package:peerm_app/services/youtube_service.dart';

void main() {
  group('UpdateService integrity', () {
    test('parses SHA256SUMS-style lines', () {
      const sums = '''
7530bdfa3194cbed95f2aeefc4fde3d30f490a0831a7e6c77979a1518eda6af3  PearMusic-Windows-x64.zip
175b8aeb4ab9f0bfea662ca457e9df075028c1efdb6b50ce8963443caac8c39e *PearMusic-Android-arm64.apk
''';
      final map = UpdateService.parseBodyChecksumsForTest(sums);
      expect(
        map['PearMusic-Windows-x64.zip'],
        '7530bdfa3194cbed95f2aeefc4fde3d30f490a0831a7e6c77979a1518eda6af3',
      );
      expect(
        map['PearMusic-Android-arm64.apk'],
        '175b8aeb4ab9f0bfea662ca457e9df075028c1efdb6b50ce8963443caac8c39e',
      );
    });

    test('parses digest + filename pairs embedded in release-body markdown', () {
      const body = '''
## Checksums
`1813a143130f327055db19c8648b75f8d657bd1aea40660c11a553148a2a0d0f` PearMusic-Android-armv7.apk
''';
      final map = UpdateService.parseBodyChecksumsForTest(body);
      expect(
        map['PearMusic-Android-armv7.apk'],
        '1813a143130f327055db19c8648b75f8d657bd1aea40660c11a553148a2a0d0f',
      );
    });

    test('computeFileSha256 matches the known empty-string digest', () async {
      final tmp = File(
        '${Directory.systemTemp.createTempSync('peerm-hash-').path}/empty.bin',
      );
      await tmp.writeAsBytes(<int>[]);
      expect(
        await UpdateService.computeFileSha256(tmp),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      tmp.deleteSync();
    });

    test('aria2cPath never throws and returns null or a path', () async {
      final result = await YoutubeService.aria2cPath();
      expect(result == null || File(result).existsSync(), isTrue);
    });
  });
}