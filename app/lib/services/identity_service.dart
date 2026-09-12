import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/song.dart';
import 'artwork_service.dart';
import 'lyrics_service.dart';
import 'stream_cache_manager.dart';

enum SortOption {
  dateAdded('Date Added'),
  title('Title'),
  size('File Size');

  final String label;
  const SortOption(this.label);
}

enum StreamingQuality {
  high('High Quality', 'Opus ~160 kbps / best audio dynamic range'),
  standard('Standard', '128 kbps AAC / fast & balanced'),
  dataSaver('Data Saver', '50–70 kbps / minimal bandwidth');

  final String label;
  final String subtitle;
  const StreamingQuality(this.label, this.subtitle);
}

/// Persistent identity + preferences for this device.
class IdentityService extends ChangeNotifier {
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
  static const _popLyricsKey = 'peerm_pop_lyrics';
  static const _playbackVolumeKey = 'peerm_playback_volume';
  static const _onlineLyricsKey = 'peerm_online_lyrics';
  static const _streamingQualityKey = 'peerm_streaming_quality';
  static const _preloadUpcomingKey = 'peerm_preload_upcoming';
  static const _onlineArtworkKey = 'peerm_online_artwork';

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
  late bool _popLyrics;
  late double _playbackVolume;
  late bool _onlineLyrics;
  late StreamingQuality _streamingQuality;
  late bool _preloadUpcoming;
  late bool _onlineArtwork;

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
    _popLyrics = _prefs.getBool(_popLyricsKey) ?? false;
    _playbackVolume = _prefs.getDouble(_playbackVolumeKey) ?? 0.75;
    _onlineLyrics = _prefs.getBool(_onlineLyricsKey) ?? true;
    final qualityStr = _prefs.getString(_streamingQualityKey);
    _streamingQuality = StreamingQuality.values.firstWhere(
      (e) => e.name == qualityStr,
      orElse: () => StreamingQuality.standard,
    );
    _preloadUpcoming = _prefs.getBool(_preloadUpcomingKey) ?? true;
    _onlineArtwork = _prefs.getBool(_onlineArtworkKey) ?? true;

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
    notifyListeners();
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
    notifyListeners();
  }

  Future<void> cacheFavoriteSongMetadata(Song song) async {
    if (_favoriteSongIds.contains(song.id) &&
        (song.sourceDeviceId == 'stream' || song.id.startsWith('stream_'))) {
      if (!_favoriteOnlineSongs.containsKey(song.id) ||
          _favoriteOnlineSongs[song.id]!.artwork != song.artwork) {
        _favoriteOnlineSongs[song.id] = song;
        await _saveFavorites();
        notifyListeners();
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
    notifyListeners();
  }

  bool get loudnessNormalization => _loudnessNormalization;

  Future<void> setLoudnessNormalization(bool value) async {
    _loudnessNormalization = value;
    await _prefs.setBool(_loudnessNormKey, value);
    notifyListeners();
  }

  bool get synthesizerBar => _synthesizerBar;

  Future<void> setSynthesizerBar(bool value) async {
    _synthesizerBar = value;
    await _prefs.setBool(_synthesizerBarKey, value);
    notifyListeners();
  }

  bool get visualizerGlow => _visualizerGlow;

  Future<void> setVisualizerGlow(bool value) async {
    if (_visualizerGlow == value) return;
    _visualizerGlow = value;
    await _prefs.setBool(_visualizerGlowKey, value);
    notifyListeners();
  }

  bool get autoRerollSeed => _autoRerollSeed;

  Future<void> setAutoRerollSeed(bool value) async {
    if (_autoRerollSeed == value) return;
    _autoRerollSeed = value;
    await _prefs.setBool(_autoRerollSeedKey, value);
    notifyListeners();
  }

  bool get autoplay => _autoplay;

  Future<void> setAutoplay(bool value) async {
    if (_autoplay == value) return;
    _autoplay = value;
    await _prefs.setBool(_autoplayKey, value);
    notifyListeners();
  }

  bool get popLyrics => _popLyrics;

  Future<void> setPopLyrics(bool value) async {
    if (_popLyrics == value) return;
    _popLyrics = value;
    await _prefs.setBool(_popLyricsKey, value);
    notifyListeners();
  }

  double get playbackVolume => _playbackVolume;

  Future<void> setPlaybackVolume(double value) async {
    final clamped = value.clamp(0.0, 1.0);
    _playbackVolume = clamped;
    await _prefs.setDouble(_playbackVolumeKey, clamped);
    notifyListeners();
  }

  bool get onlineLyrics => _onlineLyrics;

  Future<void> setOnlineLyrics(bool value) async {
    if (_onlineLyrics == value) return;
    _onlineLyrics = value;
    LyricsService.onlineLyricsEnabled = value;
    await _prefs.setBool(_onlineLyricsKey, value);
    notifyListeners();
  }

  StreamingQuality get streamingQuality => _streamingQuality;

  Future<void> setStreamingQuality(StreamingQuality value) async {
    if (_streamingQuality == value) return;
    _streamingQuality = value;
    StreamCacheManager.setStreamingQuality(value);
    await _prefs.setString(_streamingQualityKey, value.name);
    notifyListeners();
  }

  bool get preloadUpcoming => _preloadUpcoming;

  Future<void> setPreloadUpcoming(bool value) async {
    if (_preloadUpcoming == value) return;
    _preloadUpcoming = value;
    if (!value) {
      StreamCacheManager.cancelPreload();
    }
    await _prefs.setBool(_preloadUpcomingKey, value);
    notifyListeners();
  }

  bool get onlineArtwork => _onlineArtwork;

  Future<void> setOnlineArtwork(bool value) async {
    if (_onlineArtwork == value) return;
    _onlineArtwork = value;
    ArtworkService.onlineArtworkEnabled = value;
    await _prefs.setBool(_onlineArtworkKey, value);
    notifyListeners();
  }
}
