import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';

/// A single timestamped line of lyrics.
class LyricLine {
  final Duration timestamp;
  final String text;

  const LyricLine({
    required this.timestamp,
    required this.text,
  });

  @override
  String toString() =>
      '[${timestamp.inMinutes.toString().padLeft(2, '0')}:${(timestamp.inSeconds % 60).toString().padLeft(2, '0')}.${(timestamp.inMilliseconds % 1000 ~/ 10).toString().padLeft(2, '0')}] $text';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LyricLine &&
          runtimeType == other.runtimeType &&
          timestamp == other.timestamp &&
          text == other.text;

  @override
  int get hashCode => timestamp.hashCode ^ text.hashCode;
}

/// Service that parses LRC lyrics, checks local files, queries LRCLIB,
/// and caches lyrics on disk for offline playback.
class LyricsService {
  static final Map<String, List<LyricLine>> _memoryCache = {};
  static Directory? _cacheDir;
  static HttpClient? _httpClient;

  static HttpClient get _client => _httpClient ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);

  /// Parse raw LRC or plain-text lyric content into a list of [LyricLine].
  static List<LyricLine> parseLrc(String rawContent) {
    if (rawContent.trim().isEmpty) return const [];

    final lines = rawContent.split(RegExp(r'\r?\n'));
    final result = <LyricLine>[];
    final tagRegex = RegExp(r'\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]');
    final offsetRegex = RegExp(r'\[offset:\s*([+-]?\d+)\s*\]', caseSensitive: false);

    int offsetMs = 0;
    for (final line in lines) {
      final offsetMatch = offsetRegex.firstMatch(line);
      if (offsetMatch != null) {
        offsetMs = int.tryParse(offsetMatch.group(1) ?? '0') ?? 0;
        break;
      }
    }

    bool hasTimestamp = false;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final matches = tagRegex.allMatches(trimmed).toList();
      if (matches.isNotEmpty) {
        hasTimestamp = true;
        // Text is everything after the last tag
        final text = trimmed.substring(matches.last.end).trim();

        for (final match in matches) {
          final minutes = int.parse(match.group(1)!);
          final seconds = int.parse(match.group(2)!);
          final fractionStr = match.group(3);
          int millis = 0;
          if (fractionStr != null) {
            if (fractionStr.length == 1) {
              millis = int.parse(fractionStr) * 100;
            } else if (fractionStr.length == 2) {
              millis = int.parse(fractionStr) * 10;
            } else {
              millis = int.parse(fractionStr.substring(0, 3));
            }
          }

          var totalMs = (minutes * 60 * 1000) + (seconds * 1000) + millis + offsetMs;
          if (totalMs < 0) totalMs = 0;

          result.add(LyricLine(
            timestamp: Duration(milliseconds: totalMs),
            text: text,
          ));
        }
      }
    }

    if (hasTimestamp) {
      result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return result;
    }

    // Fallback for plain-text lyrics without timestamps
    final plainLines = <LyricLine>[];
    for (int i = 0; i < lines.length; i++) {
      final text = lines[i].trim();
      if (text.isNotEmpty) {
        // Space them across default intervals
        plainLines.add(LyricLine(
          timestamp: Duration(seconds: i * 5),
          text: text,
        ));
      }
    }
    return plainLines;
  }

  /// Binary/linear search to find the active lyric index given [currentPosition].
  static int findActiveIndex(List<LyricLine> lyrics, Duration currentPosition) {
    if (lyrics.isEmpty) return -1;
    if (currentPosition < lyrics.first.timestamp) return 0;

    int active = 0;
    for (int i = 0; i < lyrics.length; i++) {
      if (lyrics[i].timestamp <= currentPosition) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }

  /// Cleans titles removing common noise like "(Official Music Video)", "[HD]", etc.
  static String cleanTrackTitle(String rawTitle) {
    var cleaned = rawTitle;
    cleaned = cleaned.replaceAll(
      RegExp(r'\s*[\(\[](?:official\s+)?(?:music\s+)?(?:video|audio|lyric\s+video|visualizer|hd|4k|remaster(?:ed)?(?:\s+\d+)?|live)[\)\]]',
          caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'\s+-\s+Topic$', caseSensitive: false), '');
    return cleaned.trim();
  }

  /// Fetches lyrics for [song].
  /// 1. Checks memory cache.
  /// 2. Checks local companion `.lrc` file if available.
  /// 3. Checks persistent disk cache.
  /// 4. Queries LRCLIB online API.
  static Future<List<LyricLine>> getLyrics(
    Song song, {
    String? localAudioPath,
  }) async {
    final cacheKey = song.id;
    if (_memoryCache.containsKey(cacheKey)) {
      return _memoryCache[cacheKey]!;
    }

    // 1. Check companion local .lrc file
    if (localAudioPath != null && localAudioPath.isNotEmpty) {
      try {
        final lrcPath = p.setExtension(localAudioPath, '.lrc');
        final lrcFile = File(lrcPath);
        if (await lrcFile.exists()) {
          final content = await lrcFile.readAsString();
          final parsed = parseLrc(content);
          if (parsed.isNotEmpty) {
            _memoryCache[cacheKey] = parsed;
            return parsed;
          }
        }
      } catch (e) {
        debugPrint('[LyricsService] Local companion LRC check failed: $e');
      }
    }

    // 2. Check disk cache
    try {
      final cacheDir = await _getCacheDir();
      final cacheFile = File(p.join(cacheDir.path, '${_safeFileName(song.id)}.lrc'));
      if (await cacheFile.exists()) {
        final content = await cacheFile.readAsString();
        final parsed = parseLrc(content);
        if (parsed.isNotEmpty) {
          _memoryCache[cacheKey] = parsed;
          return parsed;
        }
      }
    } catch (e) {
      debugPrint('[LyricsService] Disk cache read error: $e');
    }

    // 3. Fetch from LRCLIB
    try {
      final fetchedLrc = await _fetchFromLrclib(song);
      if (fetchedLrc != null && fetchedLrc.isNotEmpty) {
        final parsed = parseLrc(fetchedLrc);
        if (parsed.isNotEmpty) {
          _memoryCache[cacheKey] = parsed;
          // Save to disk cache
          _saveToDiskCache(song.id, fetchedLrc);
          return parsed;
        }
      }
    } catch (e) {
      debugPrint('[LyricsService] Online fetch error: $e');
    }

    return const [];
  }

  static Future<String?> _fetchFromLrclib(Song song) async {
    final cleaned = cleanTrackTitle(song.title);

    // Try splitting "Artist - Title" or "Title - Artist"
    String? artist;
    String? track;

    if (cleaned.contains(' - ')) {
      final parts = cleaned.split(' - ');
      if (parts.length >= 2) {
        artist = parts[0].trim();
        track = parts[1].trim();
      }
    }

    // Attempt direct /api/get if artist and track are identified
    if (artist != null && track != null && artist.isNotEmpty && track.isNotEmpty) {
      final direct = await _requestLrclib(
        'https://lrclib.net/api/get',
        queryParameters: {
          'artist_name': artist,
          'track_name': track,
        },
      );
      if (direct != null) return direct;

      // Invert attempt (in case song was formatted Title - Artist)
      final directInverted = await _requestLrclib(
        'https://lrclib.net/api/get',
        queryParameters: {
          'artist_name': track,
          'track_name': artist,
        },
      );
      if (directInverted != null) return directInverted;
    }

    // Fallback: search by full cleaned query
    final searchUri = Uri.https('lrclib.net', '/api/search', {'q': cleaned});
    final results = await _requestLrclibJsonArray(searchUri);
    if (results != null && results.isNotEmpty) {
      // Prioritize synced lyrics
      for (final item in results) {
        if (item is Map<String, dynamic>) {
          final synced = item['syncedLyrics'] as String?;
          if (synced != null && synced.trim().isNotEmpty) {
            return synced;
          }
        }
      }
      // Fallback to plain lyrics
      for (final item in results) {
        if (item is Map<String, dynamic>) {
          final plain = item['plainLyrics'] as String?;
          if (plain != null && plain.trim().isNotEmpty) {
            return plain;
          }
        }
      }
    }

    return null;
  }

  static Future<String?> _requestLrclib(
    String baseUrl, {
    required Map<String, String> queryParameters,
  }) async {
    try {
      final uri = Uri.parse(baseUrl).replace(queryParameters: queryParameters);
      final req = await _client.getUrl(uri);
      req.headers.set('User-Agent', 'PearMusic/3.1.6 (https://github.com/Boci0/Pear-Music)');
      final res = await req.close();
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final data = jsonDecode(body);
        if (data is Map<String, dynamic>) {
          final synced = data['syncedLyrics'] as String?;
          if (synced != null && synced.trim().isNotEmpty) {
            return synced;
          }
          final plain = data['plainLyrics'] as String?;
          if (plain != null && plain.trim().isNotEmpty) {
            return plain;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<List<dynamic>?> _requestLrclibJsonArray(Uri uri) async {
    try {
      final req = await _client.getUrl(uri);
      req.headers.set('User-Agent', 'PearMusic/3.1.6 (https://github.com/Boci0/Pear-Music)');
      final res = await req.close();
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final data = jsonDecode(body);
        if (data is List) {
          return data;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<Directory> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, 'lyrics_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  static Future<void> _saveToDiskCache(String songId, String lrcContent) async {
    try {
      final cacheDir = await _getCacheDir();
      final cacheFile = File(p.join(cacheDir.path, '${_safeFileName(songId)}.lrc'));
      await cacheFile.writeAsString(lrcContent);
    } catch (_) {}
  }

  static String _safeFileName(String input) =>
      input.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

  @visibleForTesting
  static void clearMemoryCache() => _memoryCache.clear();
}
