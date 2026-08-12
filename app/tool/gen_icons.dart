// Generates the PeerM "pear" app icon everywhere it is needed.
//
// The user designed a childlike doodle pear: thick dark outline, interior
// filled with loose horizontal/diagonal scribble strokes in several greens
// (light lime, medium green, olive, brownish-green), a short stem and a single
// leaf on top, on a white background.
//
// This script reproduces that as a clean vector-style render and writes:
//   - Android legacy launcher icons  -> app/android/app/src/main/res/mipmap-*​/ic_launcher.png
//   - Android adaptive foregrounds   -> app/android/app/src/main/res/mipmap-*​/ic_launcher_foreground.png
//   - Adaptive icon descriptor       -> res/mipmap-anydpi-v26/ic_launcher.xml
//   - Background colour              -> res/values/colors.xml (white)
//   - Windows tray/exe icon          -> app/windows/runner/resources/app_icon.ico
//
// Run from the app/ directory:
//   dart run tool/gen_icons.dart
//
// Geometry lives in a 0..1 unit square (y grows downward); every render maps
// it onto a square canvas of the requested pixel size, so each output is
// resolution-independent.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

// ---------------------------------------------------------------------------
// Colour palette
// ---------------------------------------------------------------------------
img.Color c(int r, int g, int b) => img.ColorRgb8(r, g, b);

// Thick true-black outline (the user's simple pear has a bold black outline).
final outline = c(0x00, 0x00, 0x00);
// Solid bright lime fill.
final baseFill = c(0xBE, 0xE1, 0x2B);
// Stem / leaf fills.
final stemFill = c(0x8D, 0x6E, 0x63); // brownish-green
final leafFill = c(0x9E, 0xD8, 0x5B); // light green

// ---------------------------------------------------------------------------
// Pear geometry (unit square, y down)
// ---------------------------------------------------------------------------
class Ell {
  final double ex, ey, rx, ry;
  const Ell(this.ex, this.ey, this.rx, this.ry);
}

// The silhouette is the union of a big bottom bulb, a narrower top and a small
// neck — three overlapping ellipses.
const pearEllipses = [
  Ell(0.500, 0.674, 0.3125, 0.293), // bottom bulb
  Ell(0.500, 0.420, 0.181, 0.2295), // top
  Ell(0.500, 0.278, 0.0977, 0.1074), // neck
];

bool insidePear(double x, double y) {
  for (final e in pearEllipses) {
    final dx = (x - e.ex) / e.rx;
    final dy = (y - e.ey) / e.ry;
    if (dx * dx + dy * dy <= 1.0) return true;
  }
  return false;
}

// Exact union outline via radial march: the silhouette is star-shaped from
// this interior point, so every ray from it crosses the boundary once.
const _marchCx = 0.5, _marchCy = 0.605;

List<(double, double)> pearBoundary(int n) {
  final pts = <(double, double)>[];
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    final dx = math.cos(a), dy = math.sin(a);
    var t = 0.0, lastX = _marchCx, lastY = _marchCy;
    while (t < 1.0) {
      final x = _marchCx + dx * t;
      final y = _marchCy + dy * t;
      if (!insidePear(x, y)) break;
      lastX = x;
      lastY = y;
      t += 0.004;
    }
    pts.add((lastX, lastY));
  }
  return pts;
}

// ---------------------------------------------------------------------------
// Canvas mapping helpers
// ---------------------------------------------------------------------------
class Mapper {
  final double size;
  final double zoom;
  final double f; // unit -> px
  final double cx, cy; // centre of the pear on the canvas

  Mapper(this.size, this.zoom)
      : f = size * zoom,
        cx = size / 2,
        cy = 0.540 * size;

  double px(double ux) => cx + (ux - 0.5) * f;
  double py(double uy) => cy + (uy - 0.5) * f;
  double pr(double ur) => ur * f;
}

img.Point P(Mapper m, double ux, double uy) =>
    img.Point(m.px(ux), m.py(uy));

// ---------------------------------------------------------------------------
// Drawing helpers
// ---------------------------------------------------------------------------
void stampLine(img.Image im, Mapper m, double x1, double y1, double x2, double y2,
    img.Color color, double radiusUnit) {
  final x1p = m.px(x1), y1p = m.py(y1);
  final x2p = m.px(x2), y2p = m.py(y2);
  final d = math.sqrt((x2p - x1p) * (x2p - x1p) + (y2p - y1p) * (y2p - y1p));
  final steps = math.max(1, (d / 2).round());
  final r = m.pr(radiusUnit).round();
  for (var i = 0; i <= steps; i++) {
    final t = i / steps;
    img.fillCircle(im,
        x: (x1p + (x2p - x1p) * t).round(),
        y: (y1p + (y2p - y1p) * t).round(),
        radius: r,
        color: color,
        antialias: true);
  }
}

// A quadratic-Bezier scribble stroke (thick, round caps), used for the
// hand-drawn interior marks.
void stampScribble(img.Image im, Mapper m, double x0, double y0, double x1,
    double y1, double x2, double y2, img.Color color, double radiusUnit) {
  final steps = 40;
  double bx(double t) =>
      (1 - t) * (1 - t) * x0 + 2 * (1 - t) * t * x1 + t * t * x2;
  double by(double t) =>
      (1 - t) * (1 - t) * y0 + 2 * (1 - t) * t * y1 + t * t * y2;
  var px = bx(0), py = by(0);
  for (var i = 1; i <= steps; i++) {
    final t = i / steps;
    final nx = bx(t), ny = by(t);
    stampLine(im, m, px, py, nx, ny, color, radiusUnit);
    px = nx;
    py = ny;
  }
}

// ---------------------------------------------------------------------------
// Pear render
// ---------------------------------------------------------------------------
img.Image render({required int size, required double zoom, required bool whiteBg}) {
  final m = Mapper(size.toDouble(), zoom);
  final im = img.Image(width: size, height: size, numChannels: 4);

  if (whiteBg) {
    img.fillRect(im, x1: 0, y1: 0, x2: size, y2: size, color: img.ColorRgb8(255, 255, 255));
  }

  // 1. Solid bright-lime silhouette fill.
  final boundary = pearBoundary(220);
  img.fillPolygon(im,
      vertices: [for (final (ux, uy) in boundary) P(m, ux, uy)],
      color: baseFill);

  // 2. Thick black outline around the whole silhouette.
  final outlineR = 0.032;
  for (final (ux, uy) in boundary) {
    img.fillCircle(im,
        x: m.px(ux).round(),
        y: m.py(uy).round(),
        radius: m.pr(outlineR).round(),
        color: outline,
        antialias: true);
  }

  // 4. Stem (dark outline + brownish fill) rising from the neck.
  final stemTopY = 0.115, stemBotY = 0.205;
  stampLine(im, m, 0.5, stemBotY, 0.5, stemTopY, outline, 0.024);
  stampLine(im, m, 0.5, stemBotY - 0.004, 0.5, stemTopY + 0.004, stemFill, 0.013);

  // 5. Leaf: light-green ellipse, scribbled vein, dark outline.
  final leafCx = 0.578, leafCy = 0.145, leafRx = 0.058, leafRy = 0.026;
  final leafAngle = -0.55; // rad
  final leafPts = <(double, double)>[];
  for (var i = 0; i < 48; i++) {
    final a = 2 * math.pi * i / 48;
    final lx = math.cos(a) * leafRx, ly = math.sin(a) * leafRy;
    final rx = lx * math.cos(leafAngle) - ly * math.sin(leafAngle);
    final ry = lx * math.sin(leafAngle) + ly * math.cos(leafAngle);
    leafPts.add((leafCx + rx, leafCy + ry));
  }
  img.fillPolygon(im,
      vertices: [for (final (ux, uy) in leafPts) P(m, ux, uy)], color: leafFill);
  // Two scribble strokes inside the leaf + a centre vein.
  stampScribble(im, m, leafCx - 0.020, leafCy + 0.008, leafCx, leafCy - 0.004,
      leafCx + 0.022, leafCy - 0.006, c(0x7C, 0xB3, 0x42), 0.005);
  stampScribble(im, m, leafCx - 0.018, leafCy + 0.012, leafCx, leafCy + 0.004,
      leafCx + 0.020, leafCy + 0.004, c(0x9E, 0x9D, 0x24), 0.004);
  stampLine(im, m, leafCx - 0.036, leafCy + 0.008, leafCx + 0.034, leafCy - 0.010,
      c(0x55, 0x8B, 0x2F), 0.004);
  // Leaf outline.
  for (final (ux, uy) in leafPts) {
    img.fillCircle(im,
        x: m.px(ux).round(),
        y: m.py(uy).round(),
        radius: m.pr(0.011).round(),
        color: outline,
        antialias: true);
  }

  return im;
}

// ---------------------------------------------------------------------------
// ICO writer (PNG-compressed entries)
// ---------------------------------------------------------------------------
void writeIco(String path, Map<int, img.Image> images) {
  final sizes = images.keys.toList()..sort();
  final header = BytesBuilder();
  final dir = ByteData(6);
  dir.setUint16(0, 0, Endian.little); // reserved
  dir.setUint16(2, 1, Endian.little); // type: icon
  dir.setUint16(4, sizes.length, Endian.little);
  header.add(dir.buffer.asUint8List());

  final entries = <Uint8List>[];
  var offset = 6 + 16 * sizes.length;
  for (final s in sizes) {
    final png = img.encodePng(images[s]!);
    final e = ByteData(16);
    e.setUint8(0, s >= 256 ? 0 : s); // width (0 == 256)
    e.setUint8(1, s >= 256 ? 0 : s); // height
    e.setUint8(2, 0); // colour count
    e.setUint8(3, 0); // reserved
    e.setUint16(4, 1, Endian.little); // planes
    e.setUint16(6, 32, Endian.little); // bit count
    e.setUint32(8, png.length, Endian.little); // bytes in resource
    e.setUint32(12, offset, Endian.little); // image offset
    header.add(e.buffer.asUint8List());
    entries.add(png);
    offset += png.length;
  }
  for (final e in entries) {
    header.add(e);
  }
  File(path).writeAsBytesSync(header.takeBytes());
}

// ---------------------------------------------------------------------------
// Optional user-provided source image
// ---------------------------------------------------------------------------
// If the user drops their own pear drawing at assets/source_pear.png, every
// icon is generated from it instead of the procedural render below.
img.Image? _sourceIcon;

img.Image makeTransparent(img.Image im) {
  final out = img.Image(width: im.width, height: im.height, numChannels: 4);
  for (final p in im) {
    final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt(), a = p.a.toInt();
    if (r > 235 && g > 235 && b > 235) {
      out.setPixelRgba(p.x, p.y, 0, 0, 0, 0);
    } else {
      out.setPixelRgba(p.x, p.y, r, g, b, a);
    }
  }
  return out;
}

img.Image generateIcon(
    {required int size, required double zoom, required bool whiteBg}) {
  final src = _sourceIcon;
  if (src != null) {
    final inner = (size * zoom).round();
    final scaled = img.copyResize(src,
        width: inner, height: inner, interpolation: img.Interpolation.cubic);
    final out = img.Image(width: size, height: size, numChannels: 4);
    if (whiteBg) {
      img.fillRect(
          out, x1: 0, y1: 0, x2: size, y2: size, color: img.ColorRgb8(255, 255, 255));
    }
    img.compositeImage(
        out, scaled, dstX: (size - inner) ~/ 2, dstY: (size - inner) ~/ 2);
    return out;
  }
  return render(size: size, zoom: zoom, whiteBg: whiteBg);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
void main() {
  final root = Directory.current.path;
  final res = '$root/android/app/src/main/res';

  // Prefer a real drawing if the user saved one at assets/source_pear.png.
  final sourcePath = '$root/assets/source_pear.png';
  if (File(sourcePath).existsSync()) {
    final decoded = img.decodePng(File(sourcePath).readAsBytesSync());
    if (decoded != null) {
      _sourceIcon = makeTransparent(decoded);
      stdout.writeln('Using user-provided source: $sourcePath');
    }
  }

  // Legacy launcher icons (white background, full bleed).
  const legacySizes = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192};
  for (final e in legacySizes.entries) {
    final im = generateIcon(size: e.value, zoom: 1.0, whiteBg: true);
    File('$res/mipmap-${e.key}/ic_launcher.png').writeAsBytesSync(img.encodePng(im));
    stdout.writeln('ic_launcher ${e.key} (${e.value}px)');
  }

  // Media-notification small icon (transparent background -> the status bar /
  // notification renders a clean pear silhouette instead of the white launcher
  // square). Android tints it white in the status bar.
  const notifSizes = {'mdpi': 24, 'hdpi': 36, 'xhdpi': 48, 'xxhdpi': 72, 'xxxhdpi': 96};
  for (final e in notifSizes.entries) {
    final im = generateIcon(size: e.value, zoom: 0.85, whiteBg: false);
    File('$res/mipmap-${e.key}/ic_notification.png')
        .writeAsBytesSync(img.encodePng(im));
    stdout.writeln('ic_notification ${e.key} (${e.value}px)');
  }

  // In-app pear logo (transparent background) used in the app bar, etc.
  final assetsDir = '$root/assets';
  Directory(assetsDir).createSync(recursive: true);
  final logo = generateIcon(size: 160, zoom: 0.85, whiteBg: false);
  File('$assetsDir/pear_logo.png').writeAsBytesSync(img.encodePng(logo));
  stdout.writeln('assets/pear_logo.png (160px, transparent)');

  // Adaptive icon foregrounds (transparent background, pear in the safe zone).
  const fgSizes = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432};
  for (final e in fgSizes.entries) {
    final im = generateIcon(size: e.value, zoom: 0.85, whiteBg: false);
    File('$res/mipmap-${e.key}/ic_launcher_foreground.png')
        .writeAsBytesSync(img.encodePng(im));
    stdout.writeln('ic_launcher_foreground ${e.key} (${e.value}px)');
  }

  // Adaptive icon descriptor + background colour.
  final anydpi = Directory('$res/mipmap-anydpi-v26');
  anydpi.createSync(recursive: true);
  File('${anydpi.path}/ic_launcher.xml').writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''');
  final values = Directory('$res/values');
  final colorsPath = '${values.path}/colors.xml';
  if (!File(colorsPath).existsSync()) {
    File(colorsPath).writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#FFFFFF</color>
</resources>
''');
  } else {
    final existing = File(colorsPath).readAsStringSync();
    if (!existing.contains('ic_launcher_background')) {
      File(colorsPath).writeAsStringSync(
          existing.replaceFirst('</resources>', '    <color name="ic_launcher_background">#FFFFFF</color>\n</resources>'));
    }
  }
  stdout.writeln('adaptive icon + colours.xml written');

  // Windows .ico.
  final ico = <int, img.Image>{};
  for (final s in [16, 24, 32, 48, 64, 128, 256]) {
    ico[s] = generateIcon(size: s, zoom: 1.0, whiteBg: true);
  }
  writeIco('$root/windows/runner/resources/app_icon.ico', ico);
  stdout.writeln('app_icon.ico written');
}
