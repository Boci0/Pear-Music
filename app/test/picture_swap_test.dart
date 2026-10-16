import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/widgets/player/player_artwork.dart';
import 'package:peerm_app/widgets/player/player_video_view.dart';

void main() {
  testWidgets(
    'the picture swap shows both while fading, then only the new one',
    (tester) async {
      Widget host(bool video) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: PlayerPictureSwap(
              video: video,
              child: video
                  ? const SizedBox(
                      key: ValueKey('video'),
                      width: 300,
                      height: 170,
                    )
                  : const SizedBox(
                      key: ValueKey('cover'),
                      width: 200,
                      height: 200,
                    ),
            ),
          ),
        ),
      );

      await tester.pumpWidget(host(false));
      expect(find.byKey(const ValueKey('cover')), findsOneWidget);
      expect(find.byKey(const ValueKey('video')), findsNothing);

      await tester.pumpWidget(host(true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('cover')), findsOneWidget);
      expect(find.byKey(const ValueKey('video')), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cover')), findsNothing);
      expect(find.byKey(const ValueKey('video')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the edge feather fades the border and keeps the middle', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              child: EdgeFeather(
                width: 16,
                child: SizedBox(width: 100, height: 100),
              ),
            ),
          ),
        ),
      ),
    );
    // One mask per axis.
    expect(find.byType(ShaderMask), findsNWidgets(2));
    expect(tester.getSize(find.byType(EdgeFeather)), const Size(100, 100));
    expect(tester.takeException(), isNull);
  });
}
