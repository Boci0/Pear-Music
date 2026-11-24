import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/services/update_service.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('peerm_update_ui_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getTemporaryDirectory' ||
              call.method == 'getApplicationSupportDirectory') {
            return tempDir.path;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  testWidgets(
    'Windows updater dialog shows error, Retry, and Open release page on download failure',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      HttpServer? server;
      late BuildContext hostContext;
      try {
        await tester.runAsync(() async {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server!.listen((req) async {
            req.response.statusCode = HttpStatus.serviceUnavailable;
            await req.response.close();
          });
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) {
                  hostContext = ctx;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        );

        final zipUrl =
            'http://127.0.0.1:${server!.port}/PearMusic-Windows-x64.zip';
        final info = UpdateInfo(
          hasUpdate: true,
          currentVersion: '6.2.1',
          latestVersion: '6.2.2',
          releaseNotes: 'Bug fixes',
          htmlUrl: 'https://github.com/Boci0/Pear-Music/releases/tag/v6.2.2',
          zipUrl: zipUrl,
          sha256ByName: {'PearMusic-Windows-x64.zip': 'a' * 64},
          verified: true,
          urlsByName: {
            'PearMusic-Windows-x64.zip': [zipUrl],
          },
        );

        unawaited(UpdateService.showUpdateDialogFor(hostContext, info));
        await tester.pumpAndSettle();

        expect(find.text('Update Automatically'), findsOneWidget);

        await HttpOverrides.runWithHttpOverrides(() async {
          await tester.tap(find.text('Update Automatically'));
          await tester.pump();
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (DateTime.now().isBefore(deadline)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump();
            if (find.text('Retry').evaluate().isNotEmpty) break;
          }
        }, _RealHttpOverrides());

        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('Open release page'), findsOneWidget);
        expect(find.textContaining('Download failed (HTTP 503)'), findsOneWidget);

        await tester.tap(find.text('Later'));
        await tester.pumpAndSettle();
        expect(find.text('Retry'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        await tester.runAsync(() async {
          await server?.close(force: true);
        });
      }
    },
  );

  testWidgets(
    'Windows updater dialog shows live progress and Cancel dismisses cleanly during stalled stream',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      HttpServer? server;
      final holdStream = Completer<void>();
      late BuildContext hostContext;
      try {
        await tester.runAsync(() async {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server!.listen((req) async {
            req.response.statusCode = HttpStatus.ok;
            req.response.contentLength = 1024 * 1024;
            req.response.add(List<int>.filled(65536, 0));
            await req.response.flush();
            await holdStream.future;
            try {
              await req.response.close();
            } catch (_) {}
          });
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) {
                  hostContext = ctx;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        );

        final zipUrl =
            'http://127.0.0.1:${server!.port}/PearMusic-Windows-x64.zip';
        final info = UpdateInfo(
          hasUpdate: true,
          currentVersion: '6.2.1',
          latestVersion: '6.2.2',
          releaseNotes: 'Bug fixes',
          htmlUrl: 'https://github.com/Boci0/Pear-Music/releases/tag/v6.2.2',
          zipUrl: zipUrl,
          sha256ByName: {'PearMusic-Windows-x64.zip': 'b' * 64},
          verified: true,
          urlsByName: {
            'PearMusic-Windows-x64.zip': [zipUrl],
          },
        );

        unawaited(UpdateService.showUpdateDialogFor(hostContext, info));
        await tester.pumpAndSettle();

        await HttpOverrides.runWithHttpOverrides(() async {
          await tester.tap(find.text('Update Automatically'));
          await tester.pump();
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (DateTime.now().isBefore(deadline)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump();
            if (find.byType(LinearProgressIndicator).evaluate().isNotEmpty &&
                find.textContaining('Downloading update').evaluate().isNotEmpty) {
              break;
            }
          }
        }, _RealHttpOverrides());

        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.textContaining('Downloading update'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(LinearProgressIndicator), findsNothing);
      } finally {
        if (!holdStream.isCompleted) holdStream.complete();
        debugDefaultTargetPlatformOverride = null;
        await tester.runAsync(() async {
          await server?.close(force: true);
        });
      }
    },
  );
}
