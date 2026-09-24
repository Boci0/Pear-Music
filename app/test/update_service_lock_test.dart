import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/update_service.dart';

void main() {
  test(
    'a locked peerm_update.zip falls back to a per-attempt download name',
    () async {
      final dir = Directory.systemTemp.createTempSync('peerm_update_lock_');
      final canonical =
          File('${dir.path}${Platform.pathSeparator}peerm_update.zip');
      await canonical.writeAsBytes(List<int>.filled(2048, 7));

      // Hold the file open and mark it read-only so Windows refuses the
      // delete, which is exactly the failure users hit (errno 32).
      final handle = await canonical.open(mode: FileMode.append);
      await Process.run('attrib', ['+R', canonical.path]);
      try {
        final target = await UpdateService.resolveDownloadTargetForTesting(dir);
        expect(target.path, isNot(canonical.path),
            reason: 'must not try to reuse a file the OS will not let us delete');
        expect(target.path, contains('peerm_update_'));
        expect(target.path, endsWith('.zip'));
      } finally {
        await Process.run('attrib', ['-R', canonical.path]);
        await handle.close();
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    },
    skip: !Platform.isWindows,
  );

  test('a clean temp dir keeps using the canonical name', () async {
    final dir = Directory.systemTemp.createTempSync('peerm_update_clean_');
    try {
      final target = await UpdateService.resolveDownloadTargetForTesting(dir);
      expect(target.path, endsWith('peerm_update.zip'));
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}
