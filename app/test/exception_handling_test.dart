import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/main.dart';
import 'package:peerm_app/widgets/player/player_artwork.dart';

void main() {
  testWidgets('PearMusicErrorWidget renders safely with fallback UI', (tester) async {
    final details = FlutterErrorDetails(
      exception: Exception('Simulated widget failure'),
      stack: StackTrace.current,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PearMusicErrorWidget(details: details),
        ),
      ),
    );

    expect(find.text('Unable to display this item'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('PearMusicBootstrapErrorApp displays error message and invokes retry callback', (tester) async {
    var retryCount = 0;
    Future<void> mockRetry() async {
      retryCount++;
    }

    await tester.pumpWidget(
      PearMusicBootstrapErrorApp(
        error: Exception('Storage initialization failed'),
        stackTrace: StackTrace.current,
        onRetry: mockRetry,
      ),
    );

    expect(find.text('Unable to Start Pear Music'), findsOneWidget);
    expect(find.textContaining('Storage initialization failed'), findsOneWidget);

    final retryButton = find.widgetWithText(FilledButton, 'Retry Startup');
    expect(retryButton, findsOneWidget);

    await tester.tap(retryButton);
    await tester.pump();

    expect(retryCount, 1);
  });

  testWidgets('PlayerArtwork renders placeholder gracefully with invalid image byte stream', (tester) async {
    final corruptBytes = Uint8List.fromList([0, 1, 2, 3, 4, 5]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerArtwork(
            artwork: corruptBytes,
            size: 200,
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.byType(PlayerArtwork), findsOneWidget);
    expect(find.byIcon(Icons.music_note), findsOneWidget);
  });
}
