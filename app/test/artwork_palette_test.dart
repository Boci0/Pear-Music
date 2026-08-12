import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:peerm_app/models/song.dart';
import 'package:peerm_app/services/artwork_palette.dart';

/// Encodes a [size]x[size] solid-colour image as a base64 JPEG.
String _solidImage(Color color, {int size = 64}) {
  final image = img.Image(width: size, height: size);
  img.fill(image,
      color: img.ColorRgb8(
        (color.r * 255).round(),
        (color.g * 255).round(),
        (color.b * 255).round(),
      ));
  return base64Encode(img.encodeJpg(image));
}

void main() {
  test('solid image yields its colour (quantised), not the fallback', () {
    // A vivid red: 0xFFD01828 -> quantised to 16-step buckets (208, 16, 40).
    final c = ArtworkPalette.computeDominant(_solidImage(const Color(0xFFD01828)));
    expect(c, isNot(ArtworkPalette.fallback));
    expect(c.r, greaterThan(c.g));
    expect(c.r, greaterThan(c.b));
  });

  test('background never wins: white bg + coloured subject picks the subject',
      () {
    // 96x96 white image with a 32x32 saturated blue square in the centre.
    final image = img.Image(width: 96, height: 96);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 32; y < 64; y++) {
      for (var x = 32; x < 64; x++) {
        image.setPixelRgb(x, y, 20, 40, 220);
      }
    }
    final c =
        ArtworkPalette.computeDominant(base64Encode(img.encodeJpg(image)));
    // The extracted colour should be blue-dominant (white pixels are skipped).
    expect(c.b, greaterThan(c.r));
    expect(c.b, greaterThan(c.g));
  });

  test('song with no artwork returns the fallback without extracting',
      () async {
    final song = Song(
      id: 'x',
      title: 't',
      fileName: 'f.mp3',
      size: 1,
      checksum: 'c',
      addedAt: DateTime(2026),
    );
    expect(await ArtworkPalette.dominant(song), ArtworkPalette.fallback);
    expect(ArtworkPalette.bytes(song), isNull);
  });
}
