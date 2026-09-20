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

  test('readableAccent lifts near-black and dark colors for contrast', () {
    const nearBlack = Color(0xFF101014);
    final lifted = ArtworkPalette.readableAccent(nearBlack);
    final hsl = HSLColor.fromColor(lifted);

    // Lightness must be lifted above 0.65 for visibility on dark background
    expect(hsl.lightness, greaterThanOrEqualTo(0.65));
    // Color should have noticeable saturation
    expect(hsl.saturation, greaterThanOrEqualTo(0.35));
  });

  test('readableAccent keeps already bright colors legible', () {
    const brightCyan = Color(0xFF00E5FF);
    final result = ArtworkPalette.readableAccent(brightCyan);
    final hsl = HSLColor.fromColor(result);

    expect(hsl.lightness, greaterThanOrEqualTo(0.50));
  });

  test('microThumbnailUrl converts heavy artwork URLs into lightweight thumbnails', () {
    const ytSd = 'https://i.ytimg.com/vi/abc123xyz/sddefault.jpg';
    expect(ArtworkPalette.microThumbnailUrl(ytSd), 'https://i.ytimg.com/vi/abc123xyz/default.jpg');

    const ytHq = 'https://i.ytimg.com/vi/abc123xyz/hqdefault.jpg';
    expect(ArtworkPalette.microThumbnailUrl(ytHq), 'https://i.ytimg.com/vi/abc123xyz/default.jpg');

    const googleUser = 'https://lh3.googleusercontent.com/abc=w544-h544-l90-rj';
    expect(ArtworkPalette.microThumbnailUrl(googleUser), 'https://lh3.googleusercontent.com/abc=w96-h96-c');
  });

  test('hasResolved tracks extraction and paletteNotifier fires on success', () async {
    final song = Song(
      id: 'test_resolve',
      title: 'Resolved Test',
      fileName: 'f.mp3',
      size: 1,
      checksum: 'c',
      addedAt: DateTime(2026),
      artwork: _solidImage(const Color(0xFFFF9900)),
    );

    expect(ArtworkPalette.hasResolved(song), isFalse);

    var notified = false;
    ArtworkPalette.paletteNotifier.addListener(() {
      notified = true;
    });

    final color = await ArtworkPalette.dominant(song);
    expect(color, isNot(ArtworkPalette.fallback));
    expect(ArtworkPalette.hasResolved(song), isTrue);
    expect(notified, isTrue);
  });

  test('a dark patch behind the lyrics beats a bright cover', () async {
    // Bright cover with a dark square exactly in the middle, where the lyric
    // text renders.
    final image = img.Image(width: 96, height: 96);
    img.fill(image, color: img.ColorRgb8(240, 240, 240));
    for (var y = 36; y < 60; y++) {
      for (var x = 36; x < 60; x++) {
        image.setPixelRgb(x, y, 10, 10, 12);
      }
    }
    final bytes = img.encodeJpg(image);
    final (_, lum) = ArtworkPalette.computePaletteDataFromBytes(bytes);
    expect(lum, lessThan(0.20));

    final song = Song(
      id: 'center_dark',
      title: 'Center Dark',
      fileName: 'f.mp3',
      size: 1,
      checksum: 'c',
      addedAt: DateTime(2026),
      artwork: base64Encode(bytes),
    );
    await ArtworkPalette.dominant(song);
    expect(ArtworkPalette.prefersDarkText(song), isFalse);
  });

  test('a bright middle still prefers dark text despite dark edges', () {
    final image = img.Image(width: 96, height: 96);
    img.fill(image, color: img.ColorRgb8(240, 240, 240));
    for (var y = 0; y < 14; y++) {
      for (var x = 0; x < 96; x++) {
        image.setPixelRgb(x, y, 8, 8, 10); // dark band along the top only
      }
    }
    final (_, lum) =
        ArtworkPalette.computePaletteDataFromBytes(img.encodeJpg(image));
    expect(lum, greaterThan(0.20));
  });
}
