import 'lyrics_service.dart';

/// Copies word timing from one set of lyrics onto another without touching
/// the second one's text, offset or line times.
///
/// Used when lyrics were picked by hand from a source with no word timing:
/// each line is matched to a line of the timed lyrics by start time and text,
/// and takes that line's word spans, spread over its own text.
class LyricTimingBorrow {
  LyricTimingBorrow._();

  /// How far apart two lines may start and still be the same line.
  static const Duration matchWindow = Duration(seconds: 2);

  /// Minimum text similarity (0 to 1) for two lines to count as the same.
  static const double minLineSimilarity = 0.75;

  /// Share of lines that must find a match; below it the timing does not fit
  /// the song and nothing is changed.
  static const double minMatchedShare = 0.7;

  static final RegExp _lineTags = RegExp(
    r'^\s*((?:\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\])+)(.*)$',
  );
  static final RegExp _oneTag = RegExp(
    r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]',
  );
  static final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// [userRaw] with word tags from [timedLrc] added to every line that has a
  /// confident match, or null when too few lines match. Lines already carrying
  /// word timing, empty lines and header or mark lines are left as they are.
  static String? merge(String userRaw, String timedLrc) {
    final timed = [
      for (final l in LyricsService.parseLrc(timedLrc))
        if (l.words.isNotEmpty) l,
    ];
    if (timed.isEmpty) return null;
    final offsetMs = LyricsService.extractOffsetMs(userRaw);
    final used = <LyricLine>{};

    var total = 0;
    var matched = 0;
    final out = <String>[];
    for (final raw in userRaw.split(RegExp(r'\r?\n'))) {
      final m = _lineTags.firstMatch(raw);
      final text = m?.group(2)?.trim() ?? '';
      if (m == null || text.isEmpty || text.contains('<')) {
        out.add(raw);
        continue;
      }
      for (final tag in _oneTag.allMatches(m.group(1)!)) {
        final rawMs = _millis(tag);
        total++;
        final line = _bestMatch(
          timed,
          used,
          text,
          Duration(milliseconds: rawMs + offsetMs),
        );
        final built = line == null ? null : _build(rawMs, text, line);
        if (built == null) {
          out.add('${tag.group(0)}$text');
          continue;
        }
        used.add(line!);
        matched++;
        out.add(built);
      }
    }
    if (total == 0 || matched / total < minMatchedShare) return null;
    return out.join('\n');
  }

  static LyricLine? _bestMatch(
    List<LyricLine> timed,
    Set<LyricLine> used,
    String text,
    Duration at,
  ) {
    final wanted = _normalize(text);
    LyricLine? best;
    var bestScore = 0.0;
    var bestGap = const Duration(days: 1);
    for (final line in timed) {
      if (used.contains(line)) continue;
      final gap = (line.timestamp - at).abs();
      if (gap > matchWindow) continue;
      final score = _similarity(wanted, _normalize(line.text));
      if (score < minLineSimilarity) continue;
      if (score > bestScore || (score == bestScore && gap < bestGap)) {
        best = line;
        bestScore = score;
        bestGap = gap;
      }
    }
    return best;
  }

  /// [text] as a line starting at [rawMs], its characters spread over the
  /// words of [timed] in proportion to their length. The words are timed
  /// relative to the line start, so they follow the line wherever it is.
  static String? _build(int rawMs, String text, LyricLine timed) {
    final words = timed.words;
    final lengths = [for (final w in words) _count(w.text)];
    final totalWordChars = lengths.fold<int>(0, (a, b) => a + b);
    final textChars = _count(text);
    if (totalWordChars == 0 || textChars == 0) return null;

    var firstWord = lengths.indexWhere((n) => n > 0);
    final groups = <(int, StringBuffer)>[];
    var current = firstWord;
    var seen = 0;
    var boundary = 0;
    var upTo = lengths[0];
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      if (_letterOrDigit.hasMatch(ch)) {
        final pos = (seen + 0.5) / textChars * totalWordChars;
        seen++;
        while (boundary < words.length - 1 && upTo <= pos) {
          boundary++;
          upTo += lengths[boundary];
        }
        current = boundary;
      }
      if (groups.isEmpty || groups.last.$1 != current) {
        groups.add((current, StringBuffer()));
      }
      groups.last.$2.write(ch);
    }

    int at(Duration d) =>
        (rawMs + (d - timed.timestamp).inMilliseconds).clamp(0, 1 << 31);
    final out = StringBuffer('[${_stamp(rawMs)}]');
    for (var i = 0; i < groups.length; i++) {
      final word = words[groups[i].$1];
      final start = at(word.start);
      out.write('<${_stamp(start)}>${groups[i].$2}');
      final end = word.end;
      if (end == null) continue;
      final endMs = at(end);
      final nextStart =
          i + 1 < groups.length ? at(words[groups[i + 1].$1].start) : null;
      // Same rule the timed lyrics use: mark where a word stops only when it
      // stops short of the next one.
      if (nextStart == null || nextStart - endMs > 50) {
        out.write('<${_stamp(endMs)}>');
      }
    }
    return out.toString();
  }

  static int _count(String s) =>
      _letterOrDigit.allMatches(s).length;

  static String _normalize(String s) =>
      _letterOrDigit.allMatches(s.toLowerCase()).map((m) => m.group(0)).join();

  /// Dice coefficient over character pairs.
  static double _similarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    if (a.length < 2 || b.length < 2) return 0;
    final pairs = <String, int>{};
    for (var i = 0; i < a.length - 1; i++) {
      pairs.update(a.substring(i, i + 2), (n) => n + 1, ifAbsent: () => 1);
    }
    var shared = 0;
    for (var i = 0; i < b.length - 1; i++) {
      final key = b.substring(i, i + 2);
      final left = pairs[key] ?? 0;
      if (left > 0) {
        pairs[key] = left - 1;
        shared++;
      }
    }
    return 2 * shared / ((a.length - 1) + (b.length - 1));
  }

  static int _millis(RegExpMatch m) {
    final fraction = m.group(3);
    var ms = 0;
    if (fraction != null) {
      ms = switch (fraction.length) {
        1 => int.parse(fraction) * 100,
        2 => int.parse(fraction) * 10,
        _ => int.parse(fraction.substring(0, 3)),
      };
    }
    return int.parse(m.group(1)!) * 60000 + int.parse(m.group(2)!) * 1000 + ms;
  }

  static String _stamp(int ms) {
    final m = ms ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        '.${(ms % 1000).toString().padLeft(3, '0')}';
  }
}
