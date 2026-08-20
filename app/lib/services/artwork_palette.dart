import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show HSLColor;
import 'package:image/image.dart' as img;

import '../models/song.dart';

/// Extracts a dominant, vibrant colour from a song's artwork and caches it per
/// song. Used to theme the player (background tint, artwork glow, controls)
/// around the album art, like Spotify / YouTube Music do.
///
/// The extraction runs in a background isolate ([compute]) so the UI thread is
/// never blocked, and the result is cached by song id so it only runs once per
/// song. Decoded artwork bytes are cached too, so the player's large artwork
/// isn't re-decoded from base64 on every rebuild.
class ArtworkPalette {
  /// Theme seed colour — the fallback for songs with no artwork.
  static const Color fallback = Color(0xFF7C4DFF);

  // Bounded LRU caches. A library can hold hundreds of songs and each decoded
  // artwork bitmap is ~256KB, so keeping every song in memory would balloon
  // RAM. Entries are re-inserted on access so the most-recently-used survive
  // eviction.
  static const int _maxBytesEntries = 96;
  static const int _maxColorEntries = 256;
  static final LinkedHashMap<String, Future<Color>> _cache =
      LinkedHashMap<String, Future<Color>>();
  static final LinkedHashMap<String, Uint8List> _bytesCache =
      LinkedHashMap<String, Uint8List>();

  static final LinkedHashMap<String, Color> _resolvedColors =
      LinkedHashMap<String, Color>();

  /// Synchronous cached color extraction for zero-latency widget rendering.
  static Color dominantSync(Song song) {
    final art = song.artwork;
    if (art == null || art.isEmpty) return fallback;
    final id = song.id;
    final cached = _resolvedColors[id];
    if (cached != null) return cached;
    // Asynchronously resolve in background isolate without blocking UI thread
    dominant(song).then((color) {
      _resolvedColors[id] = color;
      _trim(_resolvedColors, _maxColorEntries);
    });
    return fallback;
  }

  /// Returns the dominant colour for [song] (or [fallback] when the song has
  /// no artwork). The returned future is cached, so repeated calls are free.
  static Future<Color> dominant(Song song) {
    final art = song.artwork;
    if (art == null || art.isEmpty) return Future.value(fallback);
    final id = song.id;
    final cachedColor = _resolvedColors[id];
    if (cachedColor != null) return Future.value(cachedColor);
    final cached = _cache.remove(id);
    if (cached != null) {
      _cache[id] = cached; // re-insert -> move to most-recently-used end.
      return cached;
    }
    final future = _extract(art).then((color) {
      _resolvedColors[id] = color;
      _trim(_resolvedColors, _maxColorEntries);
      return color;
    });
    _cache[id] = future;
    _trim(_cache, _maxColorEntries);
    return future;
  }

  /// Decoded (base64 -> bytes) artwork for [song].
  /// Returns null when the song has no artwork.
  static Uint8List? bytes(Song song) => song.artworkBytes;

  static void _trim<K, V>(LinkedHashMap<K, V> map, int max) {
    while (map.length > max) {
      map.remove(map.keys.first);
    }
  }

  static Future<Color> _extract(String base64Art) async {
    try {
      return await compute(computeDominant, base64Art);
    } catch (_) {
      return fallback;
    }
  }

  /// A softened, readable accent for controls (play button, sliders, active
  /// highlights). Raw album colours can be too dark or too neon to tint a
  /// control with, so this desaturates and brightens them: saturation is
  /// clamped to a calm 0.28-0.52 and lightness to a readable 0.56-0.72.
  static Color controlAccent(Color accent) {
    final hsl = HSLColor.fromColor(accent);
    return hsl
        .withSaturation(hsl.saturation.clamp(0.28, 0.52))
        .withLightness(hsl.lightness.clamp(0.56, 0.72))
        .toColor();
  }

  /// A dark, low-key tint of [accent] used to subtly wash a surface (e.g. the
  /// player background or the mini-player bar) with the artwork's colour
  /// without overpowering it. Lower [lightness] = more subtle.
  static Color wash(Color accent, {double lightness = 0.10}) =>
      HSLColor.fromColor(accent).withLightness(lightness).toColor();

  /// Runs in a background isolate: decodes, downsamples, and picks the most
  /// "vibrant" frequent colour — penalising near-black / near-white / gray
  /// pixels so a plain background never wins over the actual art.
  static Color computeDominant(String base64Art) {
    final bytes = base64Decode(base64Art);
    final decoded = img.decodeImage(Uint8List.fromList(bytes));
    if (decoded == null) return fallback;
    final small = img.copyResize(decoded, width: 32, height: 32);

    final counts = <int, int>{};
    for (final p in small) {
      final r = (p.r.toInt() ~/ 16) * 16;
      final g = (p.g.toInt() ~/ 16) * 16;
      final b = (p.b.toInt() ~/ 16) * 16;
      final key = (r << 16) | (g << 8) | b;
      counts[key] = (counts[key] ?? 0) + 1;
    }

    int? best;
    double bestScore = -1;
    for (final entry in counts.entries) {
      final key = entry.key;
      final r = (key >> 16) & 0xFF;
      final g = (key >> 8) & 0xFF;
      final b = key & 0xFF;
      final maxC = math.max(r, math.max(g, b));
      final minC = math.min(r, math.min(g, b));
      final sat = (maxC - minC) / 255.0;
      final lum = (maxC + minC) / 510.0;
      var score = entry.value * (1 + sat * 2);
      if (lum < 0.12 || lum > 0.88) score *= 0.3; // near black / white
      if (sat < 0.2) score *= 0.5; // gray
      if (score > bestScore) {
        bestScore = score;
        best = key;
      }
    }

    if (best == null) return fallback;
    return Color(0xFF000000 | best);
  }
}
