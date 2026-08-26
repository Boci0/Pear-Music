import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import 'artwork_palette.dart';

/// Generates (once) a default album-art placeholder PNG and returns its
/// [Uri] for use as [MediaItem.artUri].
class ArtworkService {
  static const int _size = 600;

  static Future<Uri>? _pending;

  /// Returns a file [Uri] to the default artwork. The first caller renders it;
  /// everyone else gets the shared (already-resolved or in-flight) future.
  static Future<Uri> defaultArtworkUri() => _pending ??= _loadOrCreate();

  /// Resolves the best artwork [Uri] for a specific [song] for notification display.
  static Future<Uri> songArtworkUri(Song song) async {
    final art = song.artwork;
    if (art != null && art.startsWith('http')) {
      final parsed = Uri.tryParse(art);
      if (parsed != null) return parsed;
    }

    try {
      final bytes = ArtworkPalette.bytes(song) ?? await ArtworkPalette.bytesAsync(song);
      if (bytes != null && bytes.isNotEmpty) {
        final dir = await getApplicationCacheDirectory();
        final safeId = song.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
        final file = File('${dir.path}/artwork/song_$safeId.jpg');
        if (!await file.exists()) {
          await file.create(recursive: true);
          await file.writeAsBytes(bytes, flush: true);
        }
        return Uri.file(file.path);
      }
    } catch (e) {
      debugPrint('[artwork] failed to resolve song artwork: $e');
    }

    return await defaultArtworkUri();
  }

  /// Kick off artwork generation early (e.g. from [PlayerService.init]) so the
  /// notification is ready before the user's first play.
  static void warmUp() {
    unawaited(_warmUp());
  }

  static Future<void> _warmUp() async {
    try {
      await defaultArtworkUri();
    } catch (e) {
      debugPrint('[artwork] warm-up failed: $e');
    }
  }

  static Future<Uri> _loadOrCreate() async {
    final dir = await getApplicationCacheDirectory();
    // `default_pear.png` (not `default.png`) so switching from the old vinyl
    // placeholder to the pear icon busts the stale on-disk cache.
    final file = File('${dir.path}/artwork/default_pear.png');
    if (await file.exists()) return Uri.file(file.path);
    try {
      final bytes = await _render();
      await file.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return Uri.file(file.path);
    } catch (e) {
      debugPrint('[artwork] failed to generate default artwork: $e');
      return file.uri;
    }
  }

  static Future<Uint8List> _render() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = _size.toDouble();

    // White background — same look as the launcher icon.
    canvas.drawRect(
      Offset.zero & Size(size, size),
      Paint()..color = const Color(0xFFFFFFFF),
    );

    const outline = Color(0xFF1C2A1C);
    const baseFill = Color(0xFFDDEBB2);
    const scribbleColors = [
      Color(0xFFC5E1A5),
      Color(0xFFAED581),
      Color(0xFF8BC34A),
      Color(0xFF7CB342),
      Color(0xFF9E9D24),
      Color(0xFF827717),
      Color(0xFF8D6E63),
      Color(0xFF558B2F),
    ];
    const stemFill = Color(0xFF8D6E63);
    const leafFill = Color(0xFFAED581);

    // Unit-square -> pixel mapping (zoom 1.0, same as the legacy launcher icon).
    final f = size;
    final cx = size / 2;
    final cy = 0.540 * size;
    Offset P(double ux, double uy) =>
        Offset(cx + (ux - 0.5) * f, cy + (uy - 0.5) * f);

    // 1. Base silhouette fill (light lime) so scribbles never leave holes.
    final boundary = _pearBoundary(220);
    final basePath = Path();
    for (var i = 0; i < boundary.length; i++) {
      final p = P(boundary[i].dx, boundary[i].dy);
      if (i == 0) {
        basePath.moveTo(p.dx, p.dy);
      } else {
        basePath.lineTo(p.dx, p.dy);
      }
    }
    basePath.close();
    canvas.drawPath(basePath, Paint()..color = baseFill);

    // 2. Scribble interior: dense short horizontal/diagonal strokes in greens.
    final rng = math.Random(0x50A); // fixed seed -> reproducible icon
    final outlineR = 0.022 * f;
    for (var i = 0; i < 150; i++) {
      var x = 0.0, y = 0.0, tries = 0;
      do {
        x = 0.28 + rng.nextDouble() * 0.44;
        y = 0.20 + rng.nextDouble() * 0.58;
        tries++;
      } while (!_insidePear(x, y) && tries < 50);
      if (!_insidePear(x, y)) continue;

      final ang = rng.nextDouble() < 0.75
          ? (rng.nextDouble() - 0.5) * 1.9
          : (rng.nextDouble() < 0.5
              ? -1.5 + rng.nextDouble() * 0.9
              : 0.6 + rng.nextDouble() * 0.9);
      final len = 0.055 + rng.nextDouble() * 0.11;
      final half = len / 2;
      final dx = math.cos(ang) * half, dy = math.sin(ang) * half;
      final cxx = x + (rng.nextDouble() - 0.5) * len * 0.6;
      final cyy = y + (rng.nextDouble() - 0.5) * len * 0.6;
      final col = scribbleColors[rng.nextInt(scribbleColors.length)];
      _stampScribble(
        canvas,
        P(x - dx, y - dy),
        P(cxx, cyy),
        P(x + dx, y + dy),
        col,
        (0.009 + rng.nextDouble() * 0.006) * f,
      );
    }

    // 3. Thick dark outline around the whole silhouette.
    for (final p in boundary) {
      canvas.drawCircle(P(p.dx, p.dy), outlineR, Paint()..color = outline);
    }

    // 4. Stem (dark outline + brownish fill) rising from the neck.
    const stemTopY = 0.115, stemBotY = 0.205;
    _stampLine(
        canvas, P(0.5, stemBotY), P(0.5, stemTopY), outline, 0.024 * f);
    _stampLine(canvas, P(0.5, stemBotY - 0.004), P(0.5, stemTopY + 0.004),
        stemFill, 0.013 * f);

    // 5. Leaf: light-green ellipse, scribbled vein, dark outline.
    const leafCx = 0.578, leafCy = 0.145, leafRx = 0.058, leafRy = 0.026;
    const leafAngle = -0.55; // rad
    final leafPts = <Offset>[];
    for (var i = 0; i < 48; i++) {
      final a = 2 * math.pi * i / 48;
      final lx = math.cos(a) * leafRx, ly = math.sin(a) * leafRy;
      final rx = lx * math.cos(leafAngle) - ly * math.sin(leafAngle);
      final ry = lx * math.sin(leafAngle) + ly * math.cos(leafAngle);
      leafPts.add(P(leafCx + rx, leafCy + ry));
    }
    final leafPath = Path();
    for (var i = 0; i < leafPts.length; i++) {
      if (i == 0) {
        leafPath.moveTo(leafPts[i].dx, leafPts[i].dy);
      } else {
        leafPath.lineTo(leafPts[i].dx, leafPts[i].dy);
      }
    }
    leafPath.close();
    canvas.drawPath(leafPath, Paint()..color = leafFill);
    _stampScribble(
        canvas,
        P(leafCx - 0.020, leafCy + 0.008),
        P(leafCx, leafCy - 0.004),
        P(leafCx + 0.022, leafCy - 0.006),
        const Color(0xFF7CB342),
        0.005 * f);
    _stampScribble(
        canvas,
        P(leafCx - 0.018, leafCy + 0.012),
        P(leafCx, leafCy + 0.004),
        P(leafCx + 0.020, leafCy + 0.004),
        const Color(0xFF9E9D24),
        0.004 * f);
    _stampLine(canvas, P(leafCx - 0.036, leafCy + 0.008),
        P(leafCx + 0.034, leafCy - 0.010), const Color(0xFF558B2F), 0.004 * f);
    for (final p in leafPts) {
      canvas.drawCircle(p, 0.011 * f, Paint()..color = outline);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(_size, _size);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  // --- Pear geometry (mirrors tool/gen_icons.dart) -------------------------

  static const _pearEllipses = [
    (0.500, 0.674, 0.3125, 0.293), // bottom bulb
    (0.500, 0.420, 0.181, 0.2295), // top
    (0.500, 0.278, 0.0977, 0.1074), // neck
  ];

  static bool _insidePear(double x, double y) {
    for (final (ex, ey, rx, ry) in _pearEllipses) {
      final dx = (x - ex) / rx;
      final dy = (y - ey) / ry;
      if (dx * dx + dy * dy <= 1.0) return true;
    }
    return false;
  }

  // Star-shaped from this interior point: every ray crosses the boundary once.
  static const _marchCx = 0.5, _marchCy = 0.605;

  static List<Offset> _pearBoundary(int n) {
    final pts = <Offset>[];
    for (var i = 0; i < n; i++) {
      final a = 2 * math.pi * i / n;
      final dx = math.cos(a), dy = math.sin(a);
      var t = 0.0, lastX = _marchCx, lastY = _marchCy;
      while (t < 1.0) {
        final x = _marchCx + dx * t;
        final y = _marchCy + dy * t;
        if (!_insidePear(x, y)) break;
        lastX = x;
        lastY = y;
        t += 0.004;
      }
      pts.add(Offset(lastX, lastY));
    }
    return pts;
  }

  static void _stampLine(
      Canvas canvas, Offset a, Offset b, Color color, double r) {
    final d = (b - a).distance;
    final steps = math.max(1, (d / 2).round());
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      canvas.drawCircle(Offset.lerp(a, b, t)!, r, Paint()..color = color);
    }
  }

  // Quadratic-Bezier scribble stroke (thick, round caps) — hand-drawn marks.
  static void _stampScribble(Canvas canvas, Offset a, Offset c, Offset b,
      Color color, double r) {
    const steps = 40;
    double bx(double t) =>
        (1 - t) * (1 - t) * a.dx + 2 * (1 - t) * t * c.dx + t * t * b.dx;
    double by(double t) =>
        (1 - t) * (1 - t) * a.dy + 2 * (1 - t) * t * c.dy + t * t * b.dy;
    var p = Offset(bx(0), by(0));
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final q = Offset(bx(t), by(t));
      _stampLine(canvas, p, q, color, r);
      p = q;
    }
  }
}
