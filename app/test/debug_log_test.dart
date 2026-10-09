import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/debug_log.dart';

void main() {
  test('logging with the debugPrint hook from main() does not loop', () {
    final original = debugPrint;
    final printed = <String>[];
    // The same hook main() installs, printing into a list instead.
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) DebugLog.write(message, echo: false);
      if (message != null) printed.add(message);
    };
    DebugLog.echoToSystemLog = true;
    addTearDown(() {
      debugPrint = original;
      DebugLog.echoToSystemLog = false;
    });

    DebugLog.write('[player] direct line');
    debugPrint('[player] printed line');

    expect(printed, ['[player] printed line']);
    expect(DebugLog.recentLogs.last, endsWith('[player] printed line'));
  });

  test('rotation keeps the newest whole lines with non-English titles intact', () {
    final lines = [for (var i = 0; i < 10; i++) '[12:00:0$i.0] playSong "初音ミクの消失 $i"'];
    final kept = DebugLog.newestHalf(utf8.encode('${lines.join('\n')}\n'));

    final keptLines = kept.trimRight().split('\n');
    expect(keptLines, isNotEmpty);
    expect(keptLines.length, lessThan(lines.length));
    expect(keptLines, lines.sublist(lines.length - keptLines.length));
  });
}
