import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/widgets/pear_backdrop.dart';

/// Guards the watermark against display scaling: the tile is rendered at the
/// device pixel ratio for sharpness, and must still paint at its logical size
/// (it once drew 2x too large at 200 % scaling and never re-rendered when the
/// window moved to a display with a different scale).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tile is rendered at the device pixel ratio', (tester) async {
    await tester.runAsync(() async {
      for (final dpr in [1.0, 1.5, 2.0]) {
        final tile = await PearBackdrop.renderTile(dpr);
        expect(tile.width, (150 * dpr).round());
        expect(tile.height, (150 * dpr).round());
        tile.dispose();
      }
    });
  });

  testWidgets('mark keeps its logical size when the scale changes', (
    tester,
  ) async {
    final boundary = GlobalKey();

    Future<void> pumpAt(double dpr) async {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(devicePixelRatio: dpr),
          child: Theme(
            // Black glows, so only the watermark shows over the canvas.
            data: ThemeData(
              colorScheme: const ColorScheme.dark(
                surface: Colors.black,
                primary: Colors.black,
                secondary: Colors.black,
                tertiary: Colors.black,
              ),
            ),
            child: Center(
              child: RepaintBoundary(
                key: boundary,
                child: const SizedBox(
                  width: 600,
                  height: 600,
                  child: PearBackdrop(),
                ),
              ),
            ),
          ),
        ),
      );
      // The tile render started in the test's fake-async zone: each of its
      // steps (asset load, decode, rasterise) needs real time, then a pump
      // to resume.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
    }

    /// Off-to-on watermark edges across every row of a capture at 1 logical
    /// px per pixel. The count tracks how many marks fit, so it only stays
    /// put across scales if the mark keeps its logical size.
    Future<int> edges() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final count = await tester.runAsync(() async {
        final image = await render.toImage();
        final data = (await image.toByteData())!;
        var n = 0;
        for (var y = 0; y < image.height; y++) {
          var on = false;
          for (var x = 0; x < image.width; x++) {
            final lit = data.getUint8((y * image.width + x) * 4) > 3;
            if (lit && !on) n++;
            on = lit;
          }
        }
        image.dispose();
        return n;
      });
      return count!;
    }

    await pumpAt(1);
    final atOne = await edges();
    expect(atOne, greaterThan(0), reason: 'the watermark should be drawn');

    await pumpAt(2);
    final atTwo = await edges();
    // Drawn 2x too large, the 2x capture would have about half the edges.
    expect(atTwo, closeTo(atOne, atOne * 0.2));
  });
}
