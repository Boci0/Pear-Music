import 'dart:async';
import 'dart:collection';
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

/// A candidate lyrics match from LRCLIB.
class LrcCandidate {
  final int id;
  final String trackName;
  final String artistName;
  final String albumName;
  final double duration;
  final bool hasSyncedLyrics;
  final String? syncedLyrics;
  final String? plainLyrics;

  const LrcCandidate({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    required this.duration,
    required this.hasSyncedLyrics,
    this.syncedLyrics,
    this.plainLyrics,
  });

  String get lyricsContent =>
      (syncedLyrics != null && syncedLyrics!.trim().isNotEmpty)
          ? syncedLyrics!
          : (plainLyrics ?? '');

  /// Extracts the first non-empty lyric line as a preview snippet.
  String get snippet {
    final content = lyricsContent;
    if (content.isEmpty) return '';
    final lines = content.split(RegExp(r'\r?\n'));
    for (final line in lines) {
      final text = line.replaceAll(RegExp(r'\[.*?\]'), '').trim();
      if (text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }
}

/// Service that parses LRC lyrics, checks local files, queries LRCLIB,
/// and caches lyrics on disk for offline playback.
class LyricsService {
  static const int _maxMemoryEntries = 50;
  static final LinkedHashMap<String, List<LyricLine>> _memoryCache =
      LinkedHashMap<String, List<LyricLine>>();
  static final LinkedHashMap<String, String> _rawLrcCache =
      LinkedHashMap<String, String>();

  static void _setRawLrcCache(String key, String content) {
    _rawLrcCache.remove(key);
    _rawLrcCache[key] = content;
    if (_rawLrcCache.length > _maxMemoryEntries) {
      _rawLrcCache.remove(_rawLrcCache.keys.first);
    }
  }

  static void _setMemoryCache(
    String key,
    List<LyricLine> lyrics, {
    String? rawContent,
  }) {
    _memoryCache.remove(key);
    _memoryCache[key] = lyrics;
    if (rawContent != null) {
      _setRawLrcCache(key, rawContent);
    }
    if (_memoryCache.length > _maxMemoryEntries) {
      final oldestKey = _memoryCache.keys.first;
      _memoryCache.remove(oldestKey);
      _rawLrcCache.remove(oldestKey);
    }
  }

  /// Compacts in-memory parsed lyric structures during backgrounding.
  static void compactMemory() {
    _memoryCache.clear();
    _rawLrcCache.clear();
  }

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
  /// 4. Queries LRCLIB online API (duration-aware).
  static Future<List<LyricLine>> getLyrics(
    Song song, {
    String? localAudioPath,
    Duration? duration,
  }) async {
    final cacheKey = song.id;
    if (_memoryCache.containsKey(cacheKey)) {
      final cached = _memoryCache.remove(cacheKey)!;
      _memoryCache[cacheKey] = cached;
      return cached;
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
            _setMemoryCache(cacheKey, parsed, rawContent: content);
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
          _setMemoryCache(cacheKey, parsed, rawContent: content);
          return parsed;
        }
      }
    } catch (e) {
      debugPrint('[LyricsService] Disk cache read error: $e');
    }

    // 3. Fetch from LRCLIB
    try {
      final fetchedLrc = await _fetchFromLrclib(song, duration: duration);
      if (fetchedLrc != null && fetchedLrc.isNotEmpty) {
        final parsed = parseLrc(fetchedLrc);
        if (parsed.isNotEmpty) {
          _setMemoryCache(cacheKey, parsed, rawContent: fetchedLrc);
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

  static Future<String?> _fetchFromLrclib(
    Song song, {
    Duration? duration,
  }) async {
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

    final queryParams = <String, String>{};
    if (duration != null && duration.inSeconds > 0) {
      queryParams['duration'] = duration.inSeconds.toString();
    }

    // Attempt direct /api/get if artist and track are identified
    if (artist != null && track != null && artist.isNotEmpty && track.isNotEmpty) {
      final direct = await _requestLrclib(
        'https://lrclib.net/api/get',
        queryParameters: {
          ...queryParams,
          'artist_name': artist,
          'track_name': track,
        },
      );
      if (direct != null) return direct;

      // Invert attempt (in case song was formatted Title - Artist)
      final directInverted = await _requestLrclib(
        'https://lrclib.net/api/get',
        queryParameters: {
          ...queryParams,
          'artist_name': track,
          'track_name': artist,
        },
      );
      if (directInverted != null) return directInverted;
    }

    // Fallback: search by full cleaned query with duration prioritization
    final candidates = await searchCandidates(song, duration: duration);
    if (candidates.isNotEmpty) {
      return candidates.first.lyricsContent;
    }

    return null;
  }

  /// Searches LRCLIB for candidate lyrics matching [song] or a custom [query].
  /// If [duration] is supplied, results are prioritized by proximity to track length.
  static Future<List<LrcCandidate>> searchCandidates(
    Song song, {
    String? query,
    Duration? duration,
  }) async {
    final cleaned = (query != null && query.trim().isNotEmpty)
        ? query.trim()
        : cleanTrackTitle(song.title);

    final searchUri = Uri.https('lrclib.net', '/api/search', {'q': cleaned});
    final results = await _requestLrclibJsonArray(searchUri);
    if (results == null || results.isEmpty) return const [];

    final candidates = <LrcCandidate>[];
    for (final item in results) {
      if (item is Map<String, dynamic>) {
        final id = item['id'] as int? ?? 0;
        final trackName = (item['trackName'] as String?)?.trim() ?? '';
        final artistName = (item['artistName'] as String?)?.trim() ?? '';
        final albumName = (item['albumName'] as String?)?.trim() ?? '';
        final dur = (item['duration'] as num?)?.toDouble() ?? 0.0;
        final synced = item['syncedLyrics'] as String?;
        final plain = item['plainLyrics'] as String?;

        if ((synced != null && synced.trim().isNotEmpty) ||
            (plain != null && plain.trim().isNotEmpty)) {
          candidates.add(LrcCandidate(
            id: id,
            trackName: trackName,
            artistName: artistName,
            albumName: albumName,
            duration: dur,
            hasSyncedLyrics: synced != null && synced.trim().isNotEmpty,
            syncedLyrics: synced,
            plainLyrics: plain,
          ));
        }
      }
    }

    if (duration != null && duration.inSeconds > 0) {
      final targetSec = duration.inSeconds.toDouble();
      candidates.sort((a, b) {
        // 1. Synced lyrics first
        if (a.hasSyncedLyrics != b.hasSyncedLyrics) {
          return a.hasSyncedLyrics ? -1 : 1;
        }
        // 2. Proximity to target duration
        final diffA = (a.duration - targetSec).abs();
        final diffB = (b.duration - targetSec).abs();
        return diffA.compareTo(diffB);
      });
    }

    return candidates;
  }

  static final RegExp _offsetRegex =
      RegExp(r'\[offset:\s*([+-]?\d+)\s*\]', caseSensitive: false);

  /// Extracts the offset tag in milliseconds from raw LRC content.
  static int extractOffsetMs(String rawContent) {
    final match = _offsetRegex.firstMatch(rawContent);
    if (match != null) {
      return int.tryParse(match.group(1) ?? '0') ?? 0;
    }
    return 0;
  }

  /// Replaces or adds an `[offset: <ms>]` tag to raw LRC content.
  static String applyOffsetTag(String rawContent, int newOffsetMs) {
    if (_offsetRegex.hasMatch(rawContent)) {
      return rawContent.replaceAll(_offsetRegex, '[offset: $newOffsetMs]');
    } else {
      return '[offset: $newOffsetMs]\n$rawContent';
    }
  }

  /// Retrieves the current raw LRC content for [song], if available.
  static Future<String?> getRawLrc(
    Song song, {
    String? localAudioPath,
  }) async {
    final cacheKey = song.id;
    if (_rawLrcCache.containsKey(cacheKey)) {
      return _rawLrcCache[cacheKey];
    }
    // Check companion local .lrc file
    if (localAudioPath != null && localAudioPath.isNotEmpty) {
      try {
        final lrcFile = File(p.setExtension(localAudioPath, '.lrc'));
        if (await lrcFile.exists()) {
          final content = await lrcFile.readAsString();
          _setRawLrcCache(cacheKey, content);
          return content;
        }
      } catch (_) {}
    }
    // Check disk cache
    try {
      final cacheDir = await _getCacheDir();
      final cacheFile = File(p.join(cacheDir.path, '${_safeFileName(song.id)}.lrc'));
      if (await cacheFile.exists()) {
        final content = await cacheFile.readAsString();
        _setRawLrcCache(cacheKey, content);
        return content;
      }
    } catch (_) {}
    return null;
  }

  /// Gets the current timing offset (in milliseconds) applied to [song].
  static Future<int> getOffset(
    Song song, {
    String? localAudioPath,
  }) async {
    final raw = await getRawLrc(song, localAudioPath: localAudioPath);
    if (raw == null) return 0;
    return extractOffsetMs(raw);
  }

  /// Sets an explicit timing offset (in milliseconds) on [song], updates caches,
  /// and returns the newly parsed [LyricLine] list.
  static Future<List<LyricLine>> setOffset(
    Song song,
    int newOffsetMs, {
    String? localAudioPath,
  }) async {
    final raw = await getRawLrc(song, localAudioPath: localAudioPath);
    if (raw == null || raw.trim().isEmpty) return const [];

    final updatedRaw = applyOffsetTag(raw, newOffsetMs);
    final parsed = parseLrc(updatedRaw);

    final cacheKey = song.id;
    _setMemoryCache(cacheKey, parsed, rawContent: updatedRaw);

    // Persist to local companion file if present
    if (localAudioPath != null && localAudioPath.isNotEmpty) {
      try {
        final lrcFile = File(p.setExtension(localAudioPath, '.lrc'));
        if (await lrcFile.exists()) {
          await lrcFile.writeAsString(updatedRaw);
        }
      } catch (_) {}
    }

    // Persist to disk cache
    await _saveToDiskCache(song.id, updatedRaw);

    return parsed;
  }

  /// Nudges the timing offset of [song] by [deltaMs] milliseconds.
  static Future<List<LyricLine>> adjustOffset(
    Song song,
    int deltaMs, {
    String? localAudioPath,
  }) async {
    final current = await getOffset(song, localAudioPath: localAudioPath);
    return setOffset(song, current + deltaMs, localAudioPath: localAudioPath);
  }

  /// Applies a selected candidate's lyrics to [song] and caches them.
  static Future<List<LyricLine>> applyCandidate(
    Song song,
    LrcCandidate candidate, {
    String? localAudioPath,
  }) async {
    final content = candidate.lyricsContent;
    final parsed = parseLrc(content);
    final cacheKey = song.id;
    _setMemoryCache(cacheKey, parsed, rawContent: content);

    if (localAudioPath != null && localAudioPath.isNotEmpty) {
      try {
        final lrcFile = File(p.setExtension(localAudioPath, '.lrc'));
        await lrcFile.writeAsString(content);
      } catch (_) {}
    }

    await _saveToDiskCache(song.id, content);
    return parsed;
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
  static void clearMemoryCache() {
    _memoryCache.clear();
    _rawLrcCache.clear();
  }
}
