import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/song.dart';
import 'lyrics_service.dart';

/// Lyrics from NetEase Cloud Music, used next to LRCLIB mainly for its
/// word-by-word timing (its "yrc" lyrics), which LRCLIB almost never has.
///
/// This is an unofficial source: every failure (no network, a changed API,
/// no match) simply returns null and the app carries on with what it has.
class NeteaseLyrics {
  NeteaseLyrics._();

  /// Word timing is only trusted when the NetEase recording is within this
  /// of the file's length; otherwise its timing would not line up.
  static const Duration wordTimingTolerance = Duration(seconds: 3);

  static HttpClient? _httpClient;
  static HttpClient get _client =>
      _httpClient ??= HttpClient()..connectionTimeout = const Duration(seconds: 8);

  /// Lyrics for [song] as LRC text (enhanced with word tags when NetEase has
  /// word timing that fits [duration]), or null. With [wordTimingOnly] a
  /// match without usable word timing also returns null.
  static Future<NeteaseResult?> fetch(
    Song song, {
    Duration? duration,
    bool wordTimingOnly = false,
  }) async {
    try {
      final title = LyricsService.cleanTrackTitle(song.title);
      final queries = <String>{title};
      // Titles are often "Title - Artist" or "Title - English title - Artist";
      // the first part alone usually finds the original release.
      if (title.contains(' - ')) queries.add(title.split(' - ').first.trim());

      final found = <NeteaseSong>[];
      for (final q in queries) {
        if (q.isEmpty) continue;
        found.addAll(await _search(q));
      }
      final pick = pickSong(found, title, duration: duration);
      if (pick == null) return null;

      final lyric = await _getJson(
        Uri.https('music.163.com', '/api/song/lyric', {
          'id': '${pick.id}',
          'lv': '1',
          'yv': '1',
          'tv': '-1',
        }),
      );
      if (lyric is! Map) return null;
      final yrc = (lyric['yrc'] as Map?)?['lyric'] as String?;
      final lrc = (lyric['lrc'] as Map?)?['lyric'] as String?;

      final lengthFits = duration != null &&
          (pick.duration - duration).abs() <= wordTimingTolerance;
      if (yrc != null && yrc.trim().isNotEmpty && lengthFits) {
        final converted = yrcToEnhancedLrc(yrc);
        if (converted.isNotEmpty) {
          return NeteaseResult(converted, hasWordTiming: true);
        }
      }
      if (wordTimingOnly) return null;
      if (lrc != null && lrc.trim().isNotEmpty) {
        final cleaned = dropCredits(lrc);
        if (cleaned.trim().isNotEmpty) {
          return NeteaseResult(cleaned, hasWordTiming: false);
        }
      }
    } catch (e) {
      debugPrint('[NeteaseLyrics] lookup failed: $e');
    }
    return null;
  }

  static Future<List<NeteaseSong>> _search(String query) async {
    final data = await _getJson(
      Uri.https('music.163.com', '/api/cloudsearch/pc', {
        's': query,
        'type': '1',
        'limit': '10',
      }),
    );
    if (data is! Map) return const [];
    final songs = (data['result'] as Map?)?['songs'];
    if (songs is! List) return const [];
    return [
      for (final s in songs)
        if (s is Map && s['id'] is int)
          NeteaseSong(
            id: s['id'] as int,
            name: (s['name'] as String?) ?? '',
            artists: [
              for (final a in (s['ar'] as List? ?? const []))
                if (a is Map && a['name'] is String) a['name'] as String,
            ].join(', '),
            duration: Duration(milliseconds: (s['dt'] as num?)?.toInt() ?? 0),
          ),
    ];
  }

  static Future<Object?> _getJson(Uri uri) async {
    final req = await _client.getUrl(uri);
    req.headers
      ..set('User-Agent', 'Mozilla/5.0')
      ..set('Referer', 'https://music.163.com/');
    final res = await req.close().timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;
    final body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 8));
    return jsonDecode(body);
  }

  /// The search result that is this song, judged like LRCLIB results (title
  /// first, then length, then artist), or null when none is a safe match.
  @visibleForTesting
  static NeteaseSong? pickSong(
    List<NeteaseSong> found,
    String title, {
    Duration? duration,
  }) {
    NeteaseSong? best;
    var bestScore = double.negativeInfinity;
    for (final s in found) {
      final c = s.asCandidate();
      if (!LyricsService.isConfidentMatch(c, title, duration: duration)) continue;
      final score = LyricsService.matchScore(c, title, duration: duration);
      if (score > bestScore) {
        best = s;
        bestScore = score;
      }
    }
    return best;
  }

  static final RegExp _yrcLine = RegExp(r'^\[(\d+),(\d+)\](.*)$');
  /// A word runs up to the next timing mark, so words with brackets in them
  /// ("(Cover us)") stay whole.
  static final RegExp _yrcWord = RegExp(
    r'\((\d+),(\d+),\d+\)(.*?)(?=\(\d+,\d+,\d+\)|$)',
  );

  /// Credit lines NetEase puts at the top ("作词 : …", "Composer: …").
  static final RegExp _credit = RegExp(
    r'^\s*(作词|作曲|编曲|作詞|編曲|制作人|混音|母带|和声|录音|监制|出品|策划|统筹|'
    r'lyrics|lyricist|composer|arranger|producer|vocal|mix|master)\w*\s*[:：]',
    caseSensitive: false,
  );

  /// Converts NetEase word-timed lyrics (`[lineStart,lineLength](wordStart,
  /// wordLength,0)word…`, all in milliseconds) into LRC with `<mm:ss.xxx>`
  /// word tags, which the app already reads. A word that stops before the
  /// next one begins gets an end mark, so held notes and pauses keep their
  /// real length.
  @visibleForTesting
  static String yrcToEnhancedLrc(String yrc) {
    final out = StringBuffer();
    for (final raw in const LineSplitter().convert(yrc)) {
      final line = raw.trim();
      final m = _yrcLine.firstMatch(line);
      if (m == null) continue; // JSON credit blocks and blank lines
      final words = _yrcWord.allMatches(m.group(3)!).toList();
      if (words.isEmpty) continue;
      final text = words.map((w) => w.group(3)!).join();
      if (text.trim().isEmpty || _credit.hasMatch(text)) continue;

      out.write('[${_stamp(int.parse(m.group(1)!))}]');
      for (var i = 0; i < words.length; i++) {
        final start = int.parse(words[i].group(1)!);
        final end = start + int.parse(words[i].group(2)!);
        out.write('<${_stamp(start)}>${words[i].group(3)}');
        final nextStart =
            i + 1 < words.length ? int.parse(words[i + 1].group(1)!) : null;
        // Mark the end when the word stops short of the next one (or is the
        // last), so the glow holds for exactly as long as it is sung.
        if (nextStart == null || nextStart - end > 50) {
          out.write('<${_stamp(end)}>');
        }
      }
      out.writeln();
    }
    return out.toString();
  }

  /// Plain NetEase LRC without its credit lines.
  @visibleForTesting
  static String dropCredits(String lrc) => const LineSplitter()
      .convert(lrc)
      .where((l) {
        final text = l.replaceAll(RegExp(r'^(\[[^\]]*\])+'), '');
        return !_credit.hasMatch(text);
      })
      .join('\n');

  static String _stamp(int ms) {
    final m = ms ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    final f = ms % 1000;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        '.${f.toString().padLeft(3, '0')}';
  }
}

class NeteaseResult {
  final String lrc;
  final bool hasWordTiming;
  const NeteaseResult(this.lrc, {required this.hasWordTiming});
}

@visibleForTesting
class NeteaseSong {
  final int id;
  final String name;
  final String artists;
  final Duration duration;

  const NeteaseSong({
    required this.id,
    required this.name,
    required this.artists,
    required this.duration,
  });

  LrcCandidate asCandidate() => LrcCandidate(
    id: id,
    trackName: name,
    artistName: artists,
    albumName: '',
    duration: duration.inMilliseconds / 1000,
    hasSyncedLyrics: true,
  );
}
