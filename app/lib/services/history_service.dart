import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

/// One play event: which song, and when it started.
class HistoryEntry {
  final String songId;
  final DateTime playedAt;

  const HistoryEntry({required this.songId, required this.playedAt});

  Map<String, dynamic> toJson() => {
        'id': songId,
        't': playedAt.millisecondsSinceEpoch,
      };

  static HistoryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final millis = json['t'];
    return HistoryEntry(
      songId: id,
      playedAt: DateTime.fromMillisecondsSinceEpoch(
        millis is num ? millis.toInt() : 0,
      ),
    );
  }
}

/// Ordered list of played songs, most recent first.
///
/// Deliberately lightweight: only the song id and the play time are persisted
/// (no titles or artwork), so the stored JSON stays a few KB and rows resolve
/// their metadata from the library / known online songs at render time. A
/// repeat play moves the existing entry to the front instead of appending a
/// duplicate, so the list stays bounded no matter how often songs repeat.
class HistoryService extends ChangeNotifier {
  static const String prefsKey = 'peerm_play_history';

  /// Hard cap on stored entries. Older plays are dropped.
  static const int maxEntries = 200;

  final SharedPreferences _prefs;
  final List<HistoryEntry> _entries = [];

  HistoryService(this._prefs) {
    final raw = _prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          final entry = HistoryEntry.fromJson(item);
          if (entry != null && _entries.length < maxEntries) {
            _entries.add(entry);
          }
        }
      }
    } catch (_) {
      // A corrupt history is not worth failing startup over: begin empty.
      _entries.clear();
    }
  }

  List<HistoryEntry> get entries => List.unmodifiable(_entries);
  bool get isEmpty => _entries.isEmpty;
  int get length => _entries.length;

  bool contains(String songId) =>
      _entries.any((e) => e.songId == songId);

  /// Moves [song] to the front of the history.
  void record(Song song, {DateTime? at}) {
    if (song.id.isEmpty) return;
    _entries.removeWhere((e) => e.songId == song.id);
    _entries.insert(
      0,
      HistoryEntry(songId: song.id, playedAt: at ?? DateTime.now()),
    );
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    _save();
    notifyListeners();
  }

  /// Drops entries whose song no longer exists (removed from library, or a
  /// stream reference that was never registered). Keeps the list honest
  /// without the UI having to filter on every rebuild.
  void prune(bool Function(String songId) keep) {
    final before = _entries.length;
    _entries.removeWhere((e) => !keep(e.songId));
    if (_entries.length == before) return;
    _save();
    notifyListeners();
  }

  Future<void> clear() async {
    if (_entries.isEmpty) return;
    _entries.clear();
    await _prefs.remove(prefsKey);
    notifyListeners();
  }

  void _save() {
    _prefs.setString(
      prefsKey,
      jsonEncode(_entries.map((e) => e.toJson()).toList()),
    );
  }
}
