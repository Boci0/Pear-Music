import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:peerm_app/services/youtube_service.dart';

void main() {
  group('downscaleToBase64', () {
    test('center-crops and downscales an image to a small jpeg', () {
      // A 640x480 source image with a couple of distinct colors.
      final source = img.Image(width: 640, height: 480);
      img.fill(source, color: img.ColorRgb8(120, 40, 200));
      img.fillRect(
        source,
        x1: 0,
        y1: 0,
        x2: 320,
        y2: 240,
        color: img.ColorRgb8(20, 200, 90),
      );
      final png = img.encodePng(source);

      final b64 = YoutubeService.downscaleToBase64(png, size: 64);
      expect(b64, isNotNull);
      // 64x64 JPEG is small; it must decode back to a 64x64 image.
      final decoded = img.decodeImage(base64Decode(b64!));
      expect(decoded, isNotNull);
      expect(decoded!.width, 64);
      expect(decoded.height, 64);
    });
  });

  group('yt-dlp progress parser', () {
    test('parses percentage and size into bytes', () {
      final svc = YoutubeService();
      int? gotD;
      int? gotT;
      svc.parseYtDlpProgressForTest(
        '[download]  12.3% of    3.42MiB at 1.72MiB/s ETA 00:01',
        (d, t) {
          gotD = d;
          gotT = t;
        },
      );
      expect(gotT, closeTo(3.42 * 1024 * 1024, 2));
      expect(gotD, closeTo(gotT! * 0.123, 2));
    });

    test('handles KiB and approximate size markers', () {
      final svc = YoutubeService();
      int? gotD;
      int? gotT;
      svc.parseYtDlpProgressForTest(
        '[download]  50% of ~128.00KiB at 0B/s ETA 00:00',
        (d, t) {
          gotD = d;
          gotT = t;
        },
      );
      expect(gotT, closeTo(128 * 1024, 1));
      expect(gotD, closeTo((128 * 1024) * 0.5, 1));
    });

    test('ignores non-progress lines', () {
      final svc = YoutubeService();
      var calls = 0;
      svc.parseYtDlpProgressForTest(
        '[info] Downloading 3.42MiB of a video',
        (d, t) => calls++,
      );
      expect(calls, 0);
    });
  });

  group('sanitizeTitle', () {
    test('strips video noise like (Official Video) and video IDs', () {
      expect(
        YoutubeService.sanitizeTitle('Rick Astley - Never Gonna Give You Up (Official Music Video) [dQw4w9WgXcQ]'),
        'Rick Astley - Never Gonna Give You Up',
      );
      expect(
        YoutubeService.sanitizeTitle('Artist - Track Title [Official Audio]'),
        'Artist - Track Title',
      );
      expect(
        YoutubeService.sanitizeTitle('Song Name (Lyric Video) (HD)'),
        'Song Name',
      );
    });
  });
}
