import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerm_app/widgets/player/cover_band.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> solidRed() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 100, 100),
      Paint()..color = const Color(0xFFFF0000),
    );
    return recorder.endRecording().toImage(100, 100);
  }

  Future<List<int>> column(ui.Image image, int y) async {
    final data = (await image.toByteData())!;
    final i = (y * image.width + image.width ~/ 2) * 4;
    return [for (var k = 0; k < 4; k++) data.getUint8(i + k)];
  }

  testWidgets('the band is feathered out at the top and dimmed at the bottom',
      (tester) async {
    await tester.runAsync(() async {
      final cover = await solidRed();
      final band = CoverBand.bake(cover, onBrightArt: false);
      expect(band.width, CoverBand.width);
      expect(band.height, greaterThan(0));

      final top = await column(band, 0);
      final bottom = await column(band, band.height - 1);
      expect(top[3], lessThan(16)); // the feather ramp starts at nothing
      expect(bottom[3], 255);
      // Red under a 42% black dim: about 148, nothing else.
      expect(bottom[0], inInclusiveRange(135, 160));
      expect(bottom[1], lessThan(8));
    });
  });

  testWidgets('on a bright cover the dim is a pale wash, not a dark one',
      (tester) async {
    await tester.runAsync(() async {
      final cover = await solidRed();
      final band = CoverBand.bake(cover, onBrightArt: true);
      final bottom = await column(band, band.height - 1);
      expect(bottom[0], 255);
      // A white wash at 27.5% lifts the green and blue channels to about 70.
      expect(bottom[1], inInclusiveRange(55, 85));
    });
  });
}
