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
  static const int _maxBytesEntries = 96;
  static const int _maxAsyncBytesEntries = 128;
  static const int _maxColorEntries = 128;
  static final LinkedHashMap<String, Future<Color>> _cache =
      LinkedHashMap<String, Future<Color>>();
  static final LinkedHashMap<String, Uint8List> _bytesCache =
      LinkedHashMap<String, Uint8List>();
  static final LinkedHashMap<String, Future<Uint8List?>> _asyncBytesCache =
      LinkedHashMap<String, Future<Uint8List?>>();

  static final LinkedHashMap<String, Color> _resolvedColors =
      LinkedHashMap<String, Color>();
  static final LinkedHashMap<String, double> _resolvedLuminance =
      LinkedHashMap<String, double>();

  /// Aggressively compacts in-memory decoded byte caches during backgrounding.
  static void compactMemory() {
    _bytesCache.clear();
    _asyncBytesCache.clear();
    _cache.clear();
  }

  /// Notifier bumped whenever an artwork dominant color successfully resolves.
  static final ValueNotifier<int> paletteNotifier = ValueNotifier<int>(0);

  /// Checks whether a song's dominant color has been successfully resolved from its artwork.
  static bool hasResolved(Song song) => _resolvedColors.containsKey(song.id);

  /// Checks whether an artwork is considered light based on average pixel luminance
  /// or dominant color luminance (threshold > 0.46).
  static bool isLightArtwork(Song? song) {
    if (song == null) return false;
    final lum = _resolvedLuminance[song.id];
    if (lum != null) {
      return lum > 0.46;
    }
    final dominant = _resolvedColors[song.id];
    if (dominant != null) {
      return dominant.computeLuminance() > 0.46;
    }
    return false;
  }

  /// Picks the text colour polarity that maximizes readability over the
  /// artwork. Unlike [isLightArtwork] (built for decorative tinting), this
  /// uses a lower luminance threshold so saturated bright covers (red, pink,
  /// orange) get dark text instead of hard-to-read white.
  ///
  /// The stored luminance factors in the darkest tenth of the central band,
  /// so a cover that is bright overall but has a dark patch right behind the
  /// lyrics still prefers white text.
  static bool prefersDarkText(Song? song) {
    if (song == null) return false;
    final lum = _resolvedLuminance[song.id];
    if (lum != null) return lum > 0.20;
    final dominant = _resolvedColors[song.id];
    if (dominant != null) return dominant.computeLuminance() > 0.20;
    return false;
  }

  /// Last resolved accent colour. Kept across cache clears so the UI never
  /// flashes back to fallback while colours re-resolve.
  static Color? _lastAccent;

  static final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 6;

  /// Synchronous cached color extraction for zero-latency widget rendering.
  static Color dominantSync(Song song, {Color? fallbackColor}) {
    final id = song.id;
    final cached = _resolvedColors[id];
    if (cached != null) return cached;
    return fallbackColor ?? _lastAccent ?? fallback;
  }

  /// Theme accent colour for [song]. Cached per song id: runs [compute] once,
  /// then returns the resolved colour instantly on every subsequent build.
  static Future<Color> dominant(Song song, {Color? fallbackColor}) {
    final id = song.id;
    final cached = _resolvedColors[id];
    if (cached != null) return Future.value(cached);

    final inFlight = _cache[id];
    if (inFlight != null) return inFlight;

    final art = song.artwork;
    if (art == null || art.isEmpty) {
      return Future.value(fallbackColor ?? _lastAccent ?? fallback);
    }

    final future = _extract(art).then((result) {
      final color = result.$1;
      final lum = result.$2;
      if (color != null && color != fallback) {
        _resolvedColors[id] = color;
        _trim(_resolvedColors, _maxColorEntries);
        if (lum != null) {
          _resolvedLuminance[id] = lum;
          _trim(_resolvedLuminance, _maxColorEntries);
        }
        _lastAccent = color;
        paletteNotifier.value++;
        return color;
      } else {
        // Extraction failed (e.g. timeout on slow internet).
        // Evict in-flight cache so a subsequent retry or image-load callback can succeed!
        _cache.remove(id);
        return fallbackColor ?? _lastAccent ?? fallback;
      }
    }).catchError((_) {
      _cache.remove(id);
      return fallbackColor ?? _lastAccent ?? fallback;
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

  /// Returns synchronous cached decoded bytes if present, or null.
  static Uint8List? cachedBytes(Song song) {
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

  /// Asynchronously decodes artwork for [song] with caching.
  ///
  /// Small thumbnails (< 64KB) decode in < 0.1ms synchronously, avoiding the
  /// heavy 10-20ms isolate spawn penalty of `compute`. Larger artworks decode
  /// in background isolates. Results are cached by song id in a bounded LRU.
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
    if (art.length < 65536) {
      final decoded = _decodeArtwork(art);
      if (decoded != null) {
        _bytesCache[id] = decoded;
        _trim(_bytesCache, _maxBytesEntries);
      }
      final fut = Future.value(decoded);
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

  static final Map<String, Future<(Color?, double?)>> _inFlightHttpExtracts = {};

  static Future<(Color?, double?)> _extract(String art) async {
    try {
      if (art.startsWith('http')) {
        final existing = _inFlightHttpExtracts[art];
        if (existing != null) return await existing;
        final future = _fetchAndComputeDominant(art);
        _inFlightHttpExtracts[art] = future;
        try {
          return await future;
        } finally {
          _inFlightHttpExtracts.remove(art);
        }
      } else {
        return await compute(computePaletteData, art);
      }
    } catch (_) {
      return (null, null);
    }
  }

  /// Converts heavy image URLs to lightweight micro-thumbnails (~1-3 KB) for
  /// near-instant download even on congested or slow mobile connections.
  static String microThumbnailUrl(String url) {
    if (url.isEmpty) return url;
    if (url.contains('googleusercontent.com') || url.contains('ggpht.com')) {
      return url
          .replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w96-h96-c')
          .replaceAll(RegExp(r'=s\d+.*$'), '=s96-c');
    }
    if (url.contains('i.ytimg.com/') || url.contains('img.youtube.com/')) {
      return url
          .replaceAll('sddefault.jpg', 'default.jpg')
          .replaceAll('hqdefault.jpg', 'default.jpg')
          .replaceAll('mqdefault.jpg', 'default.jpg')
          .replaceAll('maxresdefault.jpg', 'default.jpg')
          .replaceAll('sddefault.webp', 'default.jpg')
          .replaceAll('hqdefault.webp', 'default.jpg')
          .replaceAll('mqdefault.webp', 'default.jpg');
    }
    return url;
  }

  static Future<Uint8List?> _downloadBytes(String url) async {
    try {
      final req = await _httpClient
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode == 200) {
        return await consolidateHttpClientResponseBytes(resp);
      }
    } catch (_) {}
    return null;
  }

  static Future<(Color?, double?)> _fetchAndComputeDominant(String url) async {
    // 1. Try micro-thumbnail first (1-3 KB) for instantaneous download on slow internet
    final microUrl = microThumbnailUrl(url);
    final microBytes = await _downloadBytes(microUrl);
    if (microBytes != null && microBytes.isNotEmpty) {
      final res = await compute(computePaletteDataFromBytes, microBytes);
      if (res.$1 != fallback) return res;
    }

    // 2. Fallback to original URL if micro-thumbnail returned fallback or failed
    if (microUrl != url) {
      final originalBytes = await _downloadBytes(url);
      if (originalBytes != null && originalBytes.isNotEmpty) {
        final res = await compute(computePaletteDataFromBytes, originalBytes);
        if (res.$1 != fallback) return res;
      }
    }
    return (null, null);
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

  /// Computes both dominant color and overall relative luminance from a base64 string.
  static (Color, double) computePaletteData(String base64Art) {
    try {
      final bytes = base64Decode(base64Art);
      return computePaletteDataFromBytes(Uint8List.fromList(bytes));
    } catch (_) {
      return (fallback, 0.0);
    }
  }

  /// Runs in a background isolate: decodes, downsamples, and picks the most
  /// "vibrant" frequent colour while calculating a center-weighted relative
  /// luminance.
  ///
  /// The luminance is weighted towards the middle of the cover because the
  /// lyric text and overlays sit there: a cover can be bright overall yet have
  /// a dark patch exactly behind the text, and the middle is what the text
  /// colour decision has to match.
  static (Color, double) computePaletteDataFromBytes(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return (fallback, 0.0);
      final small = img.copyResize(decoded, width: 32, height: 32);

      final counts = <int, int>{};
      double totalLum = 0.0;
      double totalWeight = 0.0;
      final centerLums = <double>[];

      for (final p in small) {
        final r = p.r.toInt();
        final g = p.g.toInt();
        final b = p.b.toInt();
        final lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
        // Full weight inside the central ~55% box, tapering to a quarter at
        // the very edges so vignettes and dark frames matter less.
        final dx = (p.x - 15.5).abs() / 15.5;
        final dy = (p.y - 15.5).abs() / 15.5;
        final d = math.max(dx, dy).clamp(0.0, 1.0);
        final weight = d <= 0.55 ? 1.0 : 1.0 - ((d - 0.55) / 0.45) * 0.75;
        totalLum += lum * weight;
        totalWeight += weight;
        if (d <= 0.55) centerLums.add(lum);

        final r16 = (r ~/ 16) * 16;
        final g16 = (g ~/ 16) * 16;
        final b16 = (b ~/ 16) * 16;
        final key = (r16 << 16) | (g16 << 8) | b16;
        counts[key] = (counts[key] ?? 0) + 1;
      }

      // The reported luminance blends the center-weighted mean with the 10th
      // percentile of the central band: lyrics need the middle to be bright
      // nearly everywhere, not just on average, so a dark patch right behind
      // the text still flips it to white.
      final meanLum = totalWeight > 0 ? (totalLum / totalWeight) : 0.0;
      var avgLum = meanLum;
      if (centerLums.length >= 10) {
        centerLums.sort();
        final p10 = centerLums[((centerLums.length - 1) * 0.10).floor()];
        avgLum = math.min(meanLum, p10);
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

      if (best == null) return (fallback, avgLum);
      final raw = Color(0xFF000000 | best);
      return (readableAccent(raw), avgLum);
    } catch (_) {
      return (fallback, 0.0);
    }
  }

  /// Runs in a background isolate: decodes, downsamples, and picks the most
  /// vibrant frequent colour.
  static Color computeDominant(String base64Art) =>
      computePaletteData(base64Art).$1;

  /// Runs in a background isolate on raw image bytes.
  static Color computeDominantFromBytes(Uint8List bytes) =>
      computePaletteDataFromBytes(bytes).$1;
}
