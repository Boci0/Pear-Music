import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/innertube_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('InnertubeService.cancelDownload handles non-existent video IDs cleanly', () {
    expect(() => InnertubeService.cancelDownload('non_existent_123'), returnsNormally);
  });

  test('InnertubeService.resolveAudioUrl handles empty or malformed video IDs', () async {
    final res = await InnertubeService.resolveAudioUrl('');
    expect(res, isNull);
  });

  test('InnertubeService.downloadAudioDirect returns false when stream cannot be resolved', () async {
    final tempFile = File('${Directory.systemTemp.path}/test_invalid_stream.m4a');
    final success = await InnertubeService.downloadAudioDirect('invalid_video_id_xyz', tempFile);
    expect(success, isFalse);
    expect(await tempFile.exists(), isFalse);
  });
}
