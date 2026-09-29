import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';

/// A word (or syllable) with the moment it is sung, from enhanced LRC
/// `<mm:ss.xx>` tags.
class LyricWord {
  final Duration start;
  final String text;

  const LyricWord({required this.start, required this.text});
}

/// A piece of a line (a word, or one character in Japanese or Chinese) and
/// when it is sung, used to light the line up as it is sung.
class LyricSpan {
  final String text;
  final Duration start;
  final Duration end;

  const LyricSpan(this.text, this.start, this.end);

  /// How far through this piece [position] is, from 0 to 1.
  double progressAt(Duration position) {
    if (position <= start) return 0;
    if (position >= end) return 1;
    return (position - start).inMicroseconds / (end - start).inMicroseconds;
  }
}

/// A single timestamped line of lyrics.
class LyricLine {
  final Duration timestamp;
  final String text;

  /// Per-word timing when the lyrics carry it, otherwise empty.
  final List<LyricWord> words;

  /// False for plain lyrics, whose timestamps are only placeholders.
  final bool timed;

  const LyricLine({
    required this.timestamp,
    required this.text,
    this.words = const [],
    this.timed = true,
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
    final lines = content.split(LyricsService._lineSplitRegex);
    for (final line in lines) {
      final text = line
          .replaceAll(LyricsService._bracketContentRegex, '')
          .trim();
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
  static final RegExp _lineSplitRegex = RegExp(r'\r?\n');
  static final RegExp _bracketContentRegex = RegExp(r'\[.*?\]');
  static final RegExp _tagRegex = RegExp(
    r'\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]',
  );
  static final RegExp _wordTagRegex = RegExp(
    r'<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>',
  );

  static int _tagMillis(RegExpMatch match) {
    final minutes = int.parse(match.group(1)!);
    final seconds = int.parse(match.group(2)!);
    final fraction = match.group(3);
    var millis = 0;
    if (fraction != null) {
      millis = switch (fraction.length) {
        1 => int.parse(fraction) * 100,
        2 => int.parse(fraction) * 10,
        _ => int.parse(fraction.substring(0, 3)),
      };
    }
    return minutes * 60000 + seconds * 1000 + millis;
  }

  /// Splits enhanced LRC text (`<00:12.00>Word <00:12.40>word`) into timed
  /// words. Returns the plain text and the words (empty when untagged).
  static (String, List<LyricWord>) _parseWords(String raw, int offsetMs) {
    final tags = _wordTagRegex.allMatches(raw).toList();
    if (tags.isEmpty) return (raw, const []);
    final words = <LyricWord>[];
    // Anything before the first tag is sung with the first tagged word.
    final lead = raw.substring(0, tags.first.start);
    for (var i = 0; i < tags.length; i++) {
      final end = i + 1 < tags.length ? tags[i + 1].start : raw.length;
      var text = raw.substring(tags[i].end, end);
      if (i == 0) text = lead + text;
      if (text.trim().isEmpty) continue;
      final ms = math.max(0, _tagMillis(tags[i]) + offsetMs);
      words.add(
        LyricWord(
          start: Duration(milliseconds: ms),
          text: text,
        ),
      );
    }
    final plain = raw
        .replaceAll(_wordTagRegex, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return (plain, words);
  }

  static final RegExp _offsetRegex = RegExp(
    r'\[offset:\s*([+-]?\d+)\s*\]',
    caseSensitive: false,
  );
  static final RegExp _titleNoiseRegex = RegExp(
    r'\s*[\(\[](?:official\s+)?(?:music\s+)?(?:video|audio|lyric\s+video|visualizer|hd|4k|remaster(?:ed)?(?:\s+\d+)?|live)[\)\]]',
    caseSensitive: false,
  );
  static final RegExp _topicRegex = RegExp(
    r'\s+-\s+Topic$',
    caseSensitive: false,
  );

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

  static HttpClient get _client =>
      _httpClient ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);

  /// Parse raw LRC or plain-text lyric content into a list of [LyricLine].
  static List<LyricLine> parseLrc(String rawContent) {
    if (rawContent.trim().isEmpty) return const [];

    final lines = rawContent.split(_lineSplitRegex);
    final result = <LyricLine>[];

    int offsetMs = 0;
    for (final line in lines) {
      final offsetMatch = _offsetRegex.firstMatch(line);
      if (offsetMatch != null) {
        offsetMs = int.tryParse(offsetMatch.group(1) ?? '0') ?? 0;
        break;
      }
    }

    bool hasTimestamp = false;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final matches = _tagRegex.allMatches(trimmed).toList();
      if (matches.isNotEmpty) {
        hasTimestamp = true;
        // Text is everything after the last tag, minus any per-word timing.
        final (text, words) = _parseWords(
          trimmed.substring(matches.last.end).trim(),
          offsetMs,
        );

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

          var totalMs =
              (minutes * 60 * 1000) + (seconds * 1000) + millis + offsetMs;
          if (totalMs < 0) totalMs = 0;

          result.add(
            LyricLine(
              timestamp: Duration(milliseconds: totalMs),
              text: text,
              words: words,
            ),
          );
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
        plainLines.add(
          LyricLine(
            timestamp: Duration(seconds: i * 5),
            text: text,
            timed: false,
          ),
        );
      }
    }
    return plainLines;
  }

  static const String _cjk =
      r'\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}';

  /// One CJK character, a word with its trailing space, or a run of space.
  static final RegExp _unitRegex = RegExp(
    '[$_cjk]|[^\\s$_cjk]+\\s*|\\s+',
    unicode: true,
  );
  static final RegExp _letterRegex = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final RegExp _cjkRegex = RegExp('[$_cjk]', unicode: true);

  /// When each piece of line [i] is sung.
  ///
  /// Uses the per-word times when the lyrics carry them. Otherwise it is an
  /// estimate: pieces take a typical singing time each (a CJK character about
  /// 0.22 s, a word 0.3 s plus a little per letter), squeezed to fit before
  /// the next line when the line is sung faster than that.
  static List<LyricSpan> spansFor(List<LyricLine> lyrics, int i) {
    final line = lyrics[i];
    final nextStart = i + 1 < lyrics.length ? lyrics[i + 1].timestamp : null;

    if (line.words.isNotEmpty) {
      final words = line.words;
      return [
        for (var w = 0; w < words.length; w++)
          LyricSpan(
            words[w].text,
            words[w].start,
            w + 1 < words.length
                ? words[w + 1].start
                : _capEnd(
                    words[w].start + const Duration(milliseconds: 700),
                    nextStart,
                  ),
          ),
      ];
    }

    final units = [
      for (final m in _unitRegex.allMatches(line.text)) m.group(0)!,
    ];
    final weights = [
      for (final u in units)
        !_letterRegex.hasMatch(u)
            ? 0.0
            : _cjkRegex.hasMatch(u)
            ? 0.22
            : 0.30 + 0.04 * u.trim().length,
    ];
    final natural = weights.fold<double>(0, (a, b) => a + b);
    var scale = 1.0;
    if (nextStart != null && natural > 0) {
      final room = (nextStart - line.timestamp).inMilliseconds / 1000 * 0.92;
      if (room > 0 && natural > room) scale = room / natural;
    }
    final spans = <LyricSpan>[];
    var at = line.timestamp;
    for (var u = 0; u < units.length; u++) {
      final end =
          at + Duration(microseconds: (weights[u] * scale * 1e6).round());
      spans.add(LyricSpan(units[u], at, end));
      at = end;
    }
    return spans;
  }

  static Duration _capEnd(Duration end, Duration? nextStart) =>
      nextStart != null && nextStart < end ? nextStart : end;

  /// Binary search to find the active lyric index given [currentPosition].
  static int findActiveIndex(List<LyricLine> lyrics, Duration currentPosition) {
    if (lyrics.isEmpty) return -1;
    if (currentPosition < lyrics.first.timestamp) return 0;
    if (currentPosition >= lyrics.last.timestamp) return lyrics.length - 1;

    int low = 0;
    int high = lyrics.length - 1;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      if (lyrics[mid].timestamp <= currentPosition) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return high.clamp(0, lyrics.length - 1);
  }

  /// Cleans titles removing common noise like "(Official Music Video)", "[HD]", etc.
  static String cleanTrackTitle(String rawTitle) {
    var cleaned = rawTitle.replaceAll(_titleNoiseRegex, '');
    cleaned = cleaned.replaceAll(_topicRegex, '');
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
      final cacheFile = File(
        p.join(cacheDir.path, '${_safeFileName(song.id)}.lrc'),
      );
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
    if (artist != null &&
        track != null &&
        artist.isNotEmpty &&
        track.isNotEmpty) {
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

    // Fallback: search by the full cleaned title. Only take the top result if
    // it really is this song: no lyrics beats another song's lyrics.
    final candidates = await searchCandidates(song, duration: duration);
    if (candidates.isNotEmpty &&
        isConfidentMatch(candidates.first, cleaned, duration: duration)) {
      return candidates.first.lyricsContent;
    }

    return null;
  }

  static final RegExp _wordRegex = RegExp(r'[\p{L}\p{N}]+', unicode: true);
  static const Set<String> _fillerWords = {
    'feat',
    'ft',
    'featuring',
    'official',
    'lyrics',
    'lyric',
    'audio',
    'video',
    'music',
    'remastered',
    'remaster',
    'version',
    'the',
    'a',
  };

  static Set<String> _words(String text) => {
    for (final m in _wordRegex.allMatches(text.toLowerCase()))
      if (!_fillerWords.contains(m.group(0))) m.group(0)!,
  };

  /// Share of [part]'s words that appear in [whole].
  static double _coverage(Set<String> part, Set<String> whole) {
    if (part.isEmpty) return 0;
    return part.where(whole.contains).length / part.length;
  }

  /// How well [c] fits a song titled [title] (0 to about 1). The title words
  /// weigh most, then the artist, then how close the lengths are; synced
  /// lyrics only break near ties.
  @visibleForTesting
  static double matchScore(LrcCandidate c, String title, {Duration? duration}) {
    final wanted = _words(title);
    var score =
        _coverage(_words(c.trackName), wanted) * 0.6 +
        _coverage(_words(c.artistName), wanted) * 0.25;
    if (duration != null && duration.inSeconds > 0 && c.duration > 0) {
      final diff = (c.duration - duration.inSeconds).abs();
      score += 0.15 * (1 - (diff / 20).clamp(0.0, 1.0));
      // A much longer or shorter recording is a different version at best.
      if (diff > 30) score -= 0.3;
    }
    if (c.hasSyncedLyrics) score += 0.05;
    return score;
  }

  /// Whether [c] is safe to apply without asking: its track name is in the
  /// song's title and, when both lengths are known, they roughly agree.
  @visibleForTesting
  static bool isConfidentMatch(
    LrcCandidate c,
    String title, {
    Duration? duration,
  }) {
    if (_coverage(_words(c.trackName), _words(title)) < 0.75) return false;
    if (duration != null && duration.inSeconds > 0 && c.duration > 0) {
      return (c.duration - duration.inSeconds).abs() <= 20;
    }
    return true;
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
          candidates.add(
            LrcCandidate(
              id: id,
              trackName: trackName,
              artistName: artistName,
              albumName: albumName,
              duration: dur,
              hasSyncedLyrics: synced != null && synced.trim().isNotEmpty,
              syncedLyrics: synced,
              plainLyrics: plain,
            ),
          );
        }
      }
    }

    // Best fit first, judged against what was searched for.
    final scores = {
      for (final c in candidates) c: matchScore(c, cleaned, duration: duration),
    };
    candidates.sort((a, b) => scores[b]!.compareTo(scores[a]!));
    return candidates;
  }

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
  static Future<String?> getRawLrc(Song song, {String? localAudioPath}) async {
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
      final cacheFile = File(
        p.join(cacheDir.path, '${_safeFileName(song.id)}.lrc'),
      );
      if (await cacheFile.exists()) {
        final content = await cacheFile.readAsString();
        _setRawLrcCache(cacheKey, content);
        return content;
      }
    } catch (_) {}
    return null;
  }

  /// Gets the current timing offset (in milliseconds) applied to [song].
  static Future<int> getOffset(Song song, {String? localAudioPath}) async {
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
          await lrcFile.writeAsString(updatedRaw, flush: true);
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
        await lrcFile.writeAsString(content, flush: true);
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
      req.headers.set(
        'User-Agent',
        'PearMusic/3.1.6 (https://github.com/Boci0/Pear-Music)',
      );
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final body = await res
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 8));
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
      req.headers.set(
        'User-Agent',
        'PearMusic/3.1.6 (https://github.com/Boci0/Pear-Music)',
      );
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final body = await res
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 8));
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
      final cacheFile = File(
        p.join(cacheDir.path, '${_safeFileName(songId)}.lrc'),
      );
      await cacheFile.writeAsString(lrcContent, flush: true);
    } catch (_) {}
  }

  static String _safeFileName(String input) =>
      input.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

  @visibleForTesting
  static void setLyricsForTesting(String songId, String lrc) =>
      _setMemoryCache(songId, parseLrc(lrc), rawContent: lrc);

  @visibleForTesting
  static void clearMemoryCache() {
    _memoryCache.clear();
    _rawLrcCache.clear();
  }
}
