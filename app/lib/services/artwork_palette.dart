import 'dart:collection';
import 'dart:convert';
import 'dart:io';
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
  /// Theme seed colour — the fallback for songs with no artwork (Emerald Green).
  static const Color fallback = Color(0xFF10B981);

  // Bounded LRU caches. Memory caps optimized for high responsiveness and minimal RAM.
  static const int _maxBytesEntries = 32;
  static const int _maxAsyncBytesEntries = 48;
  static const int _maxColorEntries = 128;
  static final LinkedHashMap<String, Future<Color>> _cache =
      LinkedHashMap<String, Future<Color>>();
  static final LinkedHashMap<String, Uint8List> _bytesCache =
      LinkedHashMap<String, Uint8List>();
  static final LinkedHashMap<String, Future<Uint8List?>> _asyncBytesCache =
      LinkedHashMap<String, Future<Uint8List?>>();

  static final LinkedHashMap<String, Color> _resolvedColors =
      LinkedHashMap<String, Color>();

  /// Aggressively compacts in-memory decoded byte caches during backgrounding.
  static void compactMemory() {
    _bytesCache.clear();
    _asyncBytesCache.clear();
    _cache.clear();
  }

  /// Last resolved accent colour. Kept across cache clears so the UI never
  /// flashes back to fallback while colours re-resolve.
  static Color? _lastAccent;

  static final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 6;

  /// Synchronous cached color extraction for zero-latency widget rendering.
  static Color dominantSync(Song song, {Color? fallbackColor}) {
    final id = song.id;
    final cached = _resolvedColors[id];
    if (cached != null) return cached;
    final fb = fallbackColor ?? _lastAccent ?? fallback;
    final art = song.artwork;
    if (art == null || art.isEmpty) return fb;
    // Asynchronously resolve in background isolate without blocking UI thread
    dominant(song, fallbackColor: fb).then((color) {
      _resolvedColors[id] = color;
      _lastAccent = color;
      _trim(_resolvedColors, _maxColorEntries);
    });
    return fb;
  }

  /// Returns the dominant colour for [song] (or [fallback] when the song has
  /// no artwork). The returned future is cached, so repeated calls are free.
  static Future<Color> dominant(Song song, {Color? fallbackColor}) {
    final fb = fallbackColor ?? _lastAccent ?? fallback;
    final art = song.artwork;
    if (art == null || art.isEmpty) return Future.value(fb);
    final id = song.id;
    final cachedColor = _resolvedColors[id];
    if (cachedColor != null) return Future.value(cachedColor);
    final cached = _cache.remove(id);
    if (cached != null) {
      _cache[id] = cached; // re-insert -> move to most-recently-used end.
      return cached;
    }
    final future = _extract(art).then((color) {
      final effective = (color == fallback && _lastAccent != null) ? _lastAccent! : color;
      _resolvedColors[id] = effective;
      _lastAccent = effective;
      _trim(_resolvedColors, _maxColorEntries);
      return effective;
    });
    _cache[id] = future;
    _trim(_cache, _maxColorEntries);
    return future;
  }

  /// Decoded (base64 -> bytes) artwork for [song], cached in a bounded LRU.
  /// Returns null when the song has no artwork.
  static Uint8List? bytes(Song song) {
    final art = song.artwork;
    if (art == null || art.isEmpty) return null;
    final id = song.id;
    final cached = _bytesCache.remove(id);
    if (cached != null) {
      _bytesCache[id] = cached; // re-insert -> move to most-recently-used end.
      return cached;
    }
    final decoded = _decodeArtwork(art);
    if (decoded == null) return null;
    _bytesCache[id] = decoded;
    _trim(_bytesCache, _maxBytesEntries);
    return decoded;
  }

  /// Returns decoded artwork bytes ONLY if already present in the in-memory LRU cache.
  /// Does NOT trigger synchronous base64 decoding on cache misses, keeping the UI isolate free.
  static Uint8List? cachedBytes(Song song) {
    final art = song.artwork;
    if (art == null || art.isEmpty) return null;
    final id = song.id;
    final cached = _bytesCache.remove(id);
    if (cached != null) {
      _bytesCache[id] = cached;
      return cached;
    }
    return null;
  }

  static Uint8List? _decodeArtwork(String base64Art) {
    try {
      return base64Decode(base64Art);
    } catch (_) {
      return null;
    }
  }

  /// Asynchronously decodes artwork for [song] in a background isolate.
  ///
  /// List tiles MUST use this instead of [bytes]: the synchronous base64
  /// decode of every tile that scrolls into view janks the UI thread on large
  /// libraries (hundreds of embedded JPEGs). Results are cached by song id in
  /// a bounded LRU so repeated builds are free.
  static Future<Uint8List?> bytesAsync(Song song) {
    final art = song.artwork;
    if (art == null || art.isEmpty) return Future.value(null);
    final id = song.id;
    final cachedFuture = _asyncBytesCache[id];
    if (cachedFuture != null) {
      return cachedFuture;
    }
    final syncCached = _bytesCache[id];
    if (syncCached != null) {
      final fut = Future.value(syncCached);
      _asyncBytesCache[id] = fut;
      _trim(_asyncBytesCache, _maxAsyncBytesEntries);
      return fut;
    }
    final future = compute(_decodeArtwork, art).then((decoded) {
      if (decoded != null) {
        _bytesCache.remove(id);
        _bytesCache[id] = decoded;
        _trim(_bytesCache, _maxBytesEntries);
      }
      return decoded;
    });
    _asyncBytesCache[id] = future;
    _trim(_asyncBytesCache, _maxAsyncBytesEntries);
    return future;
  }

  /// Frees the decoded-bytes cache only (the largest consumer of RAM).
  /// Colour futures and resolved colours are kept so themes survive a
  /// background/foreground cycle without flashing to the fallback colour.
  /// Called when the app is backgrounded to reclaim RAM.
  static void clearMemoryCaches() {
    _bytesCache.clear();
    _asyncBytesCache.clear();
  }

  static void _trim<K, V>(LinkedHashMap<K, V> map, int max) {
    while (map.length > max) {
      map.remove(map.keys.first);
    }
  }

  static Future<Color> _extract(String art) async {
    try {
      if (art.startsWith('http')) {
        final req = await _httpClient.getUrl(Uri.parse(art)).timeout(const Duration(seconds: 4));
        final resp = await req.close().timeout(const Duration(seconds: 4));
        if (resp.statusCode == 200) {
          final bytes = await consolidateHttpClientResponseBytes(resp);
          return await compute(computeDominantFromBytes, bytes);
        }
      } else {
        return await compute(computeDominant, art);
      }
    } catch (_) {}
    return _lastAccent ?? fallback;
  }

  /// A softened, readable accent for controls (play button, sliders, active
  /// highlights). Raw album colours can be too dark or too neon to tint a
  /// control with, so this desaturates and brightens them: saturation is
  /// clamped to a calm 0.32-0.65 and lightness to a readable 0.65-0.82.
  static Color controlAccent(Color accent) {
    final hsl = HSLColor.fromColor(accent);
    return hsl
        .withSaturation(hsl.saturation.clamp(0.32, 0.65))
        .withLightness(hsl.lightness.clamp(0.65, 0.82))
        .toColor();
  }

  /// Ensures an accent colour is bright and vibrant enough to be clearly legible
  /// as text, icons, or active highlights against dark surfaces (#121212 / #141418).
  /// Lifts dark artwork dominant tones to high-contrast lightness (at least 0.68)
  /// while keeping saturation vibrant.
  static Color readableAccent(Color accent, {double minLightness = 0.68}) {
    final hsl = HSLColor.fromColor(accent);
    final effectiveLightness = hsl.lightness < minLightness
        ? minLightness
        : hsl.lightness.clamp(0.0, 0.88);
    final effectiveSaturation = hsl.saturation < 0.35
        ? 0.42
        : hsl.saturation.clamp(0.0, 0.90);
    return hsl
        .withLightness(effectiveLightness)
        .withSaturation(effectiveSaturation)
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
    try {
      final bytes = base64Decode(base64Art);
      return computeDominantFromBytes(Uint8List.fromList(bytes));
    } catch (_) {
      return fallback;
    }
  }

  /// Runs in a background isolate on raw image bytes.
  static Color computeDominantFromBytes(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
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
        var score = entry.value * (1 + sat * 2.5);
        if (lum < 0.15 || lum > 0.88) score *= 0.3; // near black / white
        if (sat < 0.15) score *= 0.4; // gray
        if (score > bestScore) {
          bestScore = score;
          best = key;
        }
      }

      if (best == null) return fallback;
      final raw = Color(0xFF000000 | best);
      return readableAccent(raw);
    } catch (_) {
      return fallback;
    }
  }
}
