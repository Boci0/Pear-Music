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
}
