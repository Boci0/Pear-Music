import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Driver for integration_test/nav_perf_test.dart: runs it and prints the
/// PERF lines the test reports.
Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final lines = (data?['perf'] as List?)?.cast<String>() ?? const <String>[];
    for (final line in lines) {
      stdout.writeln(line);
    }
    await File('build/perf_report.json').writeAsString(jsonEncode(data));
  },
);
