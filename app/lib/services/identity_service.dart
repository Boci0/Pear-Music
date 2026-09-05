import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/song.dart';

enum SortOption {
  dateAdded('Date Added'),
  title('Title'),
  size('File Size');

  final String label;
  const SortOption(this.label);
}

/// Persistent identity + preferences for this device.
class IdentityService {
  static const _deviceIdKey = 'peerm_device_id';
  static const _deviceNameKey = 'peerm_device_name';
  static const _favoriteIdsKey = 'peerm_favorite_song_ids';
  static const _favoriteOnlineSongsKey = 'peerm_favorite_online_songs';
  static const _sortOptionKey = 'peerm_sort_option';
  static const _loudnessNormKey = 'peerm_loudness_normalization';
  static const _synthesizerBarKey = 'peerm_synthesizer_bar';
  static const _visualizerGlowKey = 'peerm_visualizer_glow';
  static const _autoRerollSeedKey = 'peerm_auto_reroll_seed';
  static const _autoplayKey = 'peerm_autoplay';

  final SharedPreferences _prefs;
  late final String deviceId;
  late String deviceName;
  late Set<String> _favoriteSongIds;
  final Map<String, Song> _favoriteOnlineSongs = {};
  late SortOption _sortOption;
  late bool _loudnessNormalization;
  late bool _synthesizerBar;
  late bool _visualizerGlow;
  late bool _autoRerollSeed;
  late bool _autoplay;

  IdentityService(this._prefs) {
    deviceId = _prefs.getString(_deviceIdKey) ?? _uuid();
    deviceName = _prefs.getString(_deviceNameKey) ?? _defaultName();

    _favoriteSongIds = Set<String>.from(_prefs.getStringList(_favoriteIdsKey) ?? []);
    final onlineJson = _prefs.getString(_favoriteOnlineSongsKey);
    if (onlineJson != null && onlineJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(onlineJson);
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            if (entry.value is Map<String, dynamic>) {
              _favoriteOnlineSongs[entry.key] =
                  Song.fromJson(entry.value as Map<String, dynamic>);
            }
          }
        }
      } catch (_) {}
    }
    final sortStr = _prefs.getString(_sortOptionKey);
    _sortOption = SortOption.values.firstWhere(
      (e) => e.name == sortStr,
      orElse: () => SortOption.dateAdded,
    );
    _loudnessNormalization = _prefs.getBool(_loudnessNormKey) ?? true;
    _synthesizerBar = _prefs.getBool(_synthesizerBarKey) ?? false;
    _visualizerGlow = _prefs.getBool(_visualizerGlowKey) ?? true;
    _autoRerollSeed = _prefs.getBool(_autoRerollSeedKey) ?? false;
    _autoplay = _prefs.getBool(_autoplayKey) ?? false;

    if (_prefs.getString(_deviceIdKey) == null) {
      _prefs.setString(_deviceIdKey, deviceId);
    }
    // Migrate the old "localhost" default (Android's hostname is literally
    // "localhost") to a friendly name so the phone never shows up as
    // "localhost" in the paired-device list.
    if (Platform.isAndroid && deviceName.toLowerCase() == 'localhost') {
      deviceName = 'My Phone';
      unawaited(_prefs.setString(_deviceNameKey, deviceName));
    }
  }

  String _uuid() => const Uuid().v4();

  String _defaultName() {
    // Try to use the OS host/device name when available. On Android this is
    // literally "localhost" (a useless name), so use a friendly default there.
    try {
      final host = Platform.localHostname;
      if (host.isNotEmpty && host.toLowerCase() != 'localhost') return host;
    } catch (_) {}
    return Platform.isAndroid ? 'My Phone' : 'My Device';
  }

  /// Set whether this device is the host (runs the embedded server).
  Future<void> setDeviceName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    deviceName = trimmed;
    await _prefs.setString(_deviceNameKey, trimmed);
  }

  Set<String> get favoriteSongIds => Set.unmodifiable(_favoriteSongIds);

  Map<String, Song> get favoriteOnlineSongs =>
      Map.unmodifiable(_favoriteOnlineSongs);

  Song? findFavoriteOnlineSong(String id) => _favoriteOnlineSongs[id];

  bool isFavorite(String songId) => _favoriteSongIds.contains(songId);

  Future<void> toggleFavorite(String songId, {Song? song}) async {
    if (_favoriteSongIds.contains(songId)) {
      _favoriteSongIds.remove(songId);
      _favoriteOnlineSongs.remove(songId);
    } else {
      _favoriteSongIds.add(songId);
      if (song != null &&
          (song.sourceDeviceId == 'stream' || song.id.startsWith('stream_'))) {
        _favoriteOnlineSongs[songId] = song;
      }
    }
    await _saveFavorites();
  }

  Future<void> cacheFavoriteSongMetadata(Song song) async {
    if (_favoriteSongIds.contains(song.id) &&
        (song.sourceDeviceId == 'stream' || song.id.startsWith('stream_'))) {
      if (!_favoriteOnlineSongs.containsKey(song.id) ||
          _favoriteOnlineSongs[song.id]!.artwork != song.artwork) {
        _favoriteOnlineSongs[song.id] = song;
        await _saveFavorites();
      }
    }
  }

  Future<void> _saveFavorites() async {
    await Future.wait([
      _prefs.setStringList(_favoriteIdsKey, _favoriteSongIds.toList()),
      _prefs.setString(
        _favoriteOnlineSongsKey,
        jsonEncode(_favoriteOnlineSongs.map((k, v) => MapEntry(k, v.toJson()))),
      ),
    ]);
  }

  SortOption get sortOption => _sortOption;

  Future<void> setSortOption(SortOption option) async {
    _sortOption = option;
    await _prefs.setString(_sortOptionKey, option.name);
  }

  bool get loudnessNormalization => _loudnessNormalization;

  Future<void> setLoudnessNormalization(bool value) async {
    _loudnessNormalization = value;
    await _prefs.setBool(_loudnessNormKey, value);
  }

  bool get synthesizerBar => _synthesizerBar;

  Future<void> setSynthesizerBar(bool value) async {
    _synthesizerBar = value;
    await _prefs.setBool(_synthesizerBarKey, value);
  }

  bool get visualizerGlow => _visualizerGlow;

  Future<void> setVisualizerGlow(bool value) async {
    if (_visualizerGlow == value) return;
    _visualizerGlow = value;
    await _prefs.setBool(_visualizerGlowKey, value);
  }

  bool get autoRerollSeed => _autoRerollSeed;

  Future<void> setAutoRerollSeed(bool value) async {
    if (_autoRerollSeed == value) return;
    _autoRerollSeed = value;
    await _prefs.setBool(_autoRerollSeedKey, value);
  }

  bool get autoplay => _autoplay;

  Future<void> setAutoplay(bool value) async {
    if (_autoplay == value) return;
    _autoplay = value;
    await _prefs.setBool(_autoplayKey, value);
  }
}
