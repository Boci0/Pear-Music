import 'stream_cache_manager.dart' show ResolvedStream;

/// Direct audio links resolved ahead of a play, so a tap on a track nobody
/// could preload starts from a link that is already known.
///
/// Links are tied to this connection and expire, and a link that was used up
/// or throttled can answer 403, so entries are single-use ([take] removes
/// them), short-lived and few.
class ResolvedLinkCache {
  ResolvedLinkCache({
    this.maxEntries = 8,
    this.maxAge = const Duration(minutes: 20),
    this.expiryMargin = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxEntries;

  /// Longest an entry is kept, however far away the link's own expiry is.
  final Duration maxAge;

  /// How long before the link's own expiry it stops being handed out.
  final Duration expiryMargin;

  final DateTime Function() _clock;

  /// Insertion ordered, so the oldest entry is the first.
  final Map<String, _Entry> _entries = {};

  int get length => _entries.length;

  /// Whether a usable link for [videoId] is held (without consuming it).
  bool contains(String videoId) => _peek(videoId) != null;

  void put(String videoId, ResolvedStream stream) {
    final now = _clock();
    var validUntil = now.add(maxAge);
    final linkExpiry = linkExpiryOf(stream.url);
    if (linkExpiry != null) {
      final cutoff = linkExpiry.subtract(expiryMargin);
      if (cutoff.isBefore(validUntil)) validUntil = cutoff;
    }
    if (!validUntil.isAfter(now)) return;
    _entries.remove(videoId);
    _entries[videoId] = _Entry(stream, validUntil);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Removes and returns the link for [videoId], or null when there is none
  /// or it has gone stale.
  ResolvedStream? take(String videoId) {
    final entry = _peek(videoId);
    _entries.remove(videoId);
    return entry?.stream;
  }

  void remove(String videoId) => _entries.remove(videoId);

  void clear() => _entries.clear();

  _Entry? _peek(String videoId) {
    final entry = _entries[videoId];
    if (entry == null) return null;
    if (!entry.validUntil.isAfter(_clock())) {
      _entries.remove(videoId);
      return null;
    }
    return entry;
  }

  /// The moment a googlevideo link stops working, from its `expire` query
  /// parameter (seconds since the epoch), or null when it has none.
  static DateTime? linkExpiryOf(String url) {
    final raw = Uri.tryParse(url)?.queryParameters['expire'];
    final seconds = raw == null ? null : int.tryParse(raw);
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }
}

class _Entry {
  const _Entry(this.stream, this.validUntil);

  final ResolvedStream stream;
  final DateTime validUntil;
}
