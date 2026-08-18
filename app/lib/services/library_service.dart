import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/playlist.dart';
import '../models/song.dart';

/// Owns the on-disk music library and its index.
///
/// Layout (under the app support directory):
///   `library/<songId>.<ext>` -> the audio files
///   `index.json`             -> metadata for every song
///   `playlists.json`         -> user playlists (ordered song IDs)
///   `_incoming/`             -> partial downloads, cleaned up on failure
class LibraryService extends ChangeNotifier {
  final List<Song> _songs = [];
  final Map<String, Song> _songsById = {};
  final Set<String> _checksums = {};
  List<Song> get songs => List.unmodifiable(_songs);

  void _indexSong(Song s) {
    _songsById[s.id] = s;
    _checksums.add(s.checksum);
  }

  void _unindexSong(Song s) {
    _songsById.remove(s.id);
    _checksums.remove(s.checksum);
  }

  final List<Playlist> _playlists = [];
  List<Playlist> get playlists => List.unmodifiable(_playlists);

  /// Songs deleted on this device (id → deletion time). Used to propagate
  /// deletions to peers and prevent re-downloading deleted songs upon reconnect.
  final Map<String, DateTime> _deletedSongsAt = {};
  Map<String, DateTime> get deletedSongsAt =>
      Map.unmodifiable(_deletedSongsAt);

  /// Audio checksums deleted on this device (checksum → deletion time).
  final Map<String, DateTime> _deletedChecksumsAt = {};
  Map<String, DateTime> get deletedChecksumsAt =>
      Map.unmodifiable(_deletedChecksumsAt);

  bool isSongDeleted(String id, [String? checksum]) =>
      _deletedSongsAt.containsKey(id) ||
      (checksum != null && _deletedChecksumsAt.containsKey(checksum));

  void recordSongDeleted(String id, {String? checksum, DateTime? at}) {
    final timestamp = at ?? DateTime.now();
    _deletedSongsAt[id] = timestamp;
    if (checksum != null && checksum.isNotEmpty) {
      _deletedChecksumsAt[checksum] = timestamp;
    }
    _pruneDeletedSongs();
  }

  void _pruneDeletedSongs() {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    _deletedSongsAt.removeWhere((_, at) => at.isBefore(cutoff));
    _deletedChecksumsAt.removeWhere((_, at) => at.isBefore(cutoff));
  }

  /// Playlists deleted on this device (id → deletion time). Used to propagate
  /// deletions to peers that were offline when the delete happened, without
  /// resurrecting them on the next manifest merge.
  final Map<String, DateTime> _deletedPlaylistsAt = {};
  Map<String, DateTime> get deletedPlaylistsAt =>
      Map.unmodifiable(_deletedPlaylistsAt);

  Directory? _libraryDir;
  File? _indexFile;
  File? _playlistsFile;

  /// Test hook: override the base directory instead of using path_provider.
  @visibleForTesting
  Directory? debugBaseDirectory;

  Future<void> init() async {
    final support = debugBaseDirectory ?? await getApplicationSupportDirectory();
    _libraryDir = Directory(p.join(support.path, 'library'));
    await _libraryDir!.create(recursive: true);
    await Directory(p.join(_libraryDir!.path, '_incoming')).create(recursive: true);
    _indexFile = File(p.join(support.path, 'index.json'));
    _playlistsFile = File(p.join(support.path, 'playlists.json'));
    await _loadIndex();
    await _loadPlaylists();
    notifyListeners();
  }

  Directory get libraryDir => _libraryDir!;

  File songFile(Song song) => File(p.join(_libraryDir!.path, song.fileName));

  bool hasSongFile(Song song) {
    try {
      final file = songFile(song);
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  File incomingFile(String songId) =>
      File(p.join(_libraryDir!.path, '_incoming', '$songId.part'));

  Future<void> _loadIndex() async {
    _songs.clear();
    _songsById.clear();
    _checksums.clear();
    _deletedSongsAt.clear();
    if (_indexFile == null || !await _indexFile!.exists()) return;
    try {
      final decoded = jsonDecode(await _indexFile!.readAsString());
      if (decoded is List) {
        final seenIds = <String>{};
        final seenChecksums = <String>{};
        var hadDuplicates = false;
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final s = Song.fromJson(item);
            if (seenIds.contains(s.id) || seenChecksums.contains(s.checksum)) {
              hadDuplicates = true;
              continue;
            }
            seenIds.add(s.id);
            seenChecksums.add(s.checksum);
            _songs.add(s);
            _indexSong(s);
          }
        }
        if (hadDuplicates) {
          await _saveIndex();
        }
      } else if (decoded is Map<String, dynamic>) {
        final seenIds = <String>{};
        final seenChecksums = <String>{};
        for (final item in decoded['songs'] as List? ?? []) {
          if (item is Map<String, dynamic>) {
            final s = Song.fromJson(item);
            if (seenIds.contains(s.id) || seenChecksums.contains(s.checksum)) {
              continue;
            }
            seenIds.add(s.id);
            seenChecksums.add(s.checksum);
            _songs.add(s);
            _indexSong(s);
          }
        }
        final deleted = decoded['deleted'];
        if (deleted is Map) {
          deleted.forEach((key, value) {
            final at = DateTime.tryParse(value.toString());
            if (at != null) _deletedSongsAt[key.toString()] = at;
          });
        }
        final deletedChecksums = decoded['deleted_checksums'];
        if (deletedChecksums is Map) {
          deletedChecksums.forEach((key, value) {
            final at = DateTime.tryParse(value.toString());
            if (at != null) _deletedChecksumsAt[key.toString()] = at;
          });
        }
        _pruneDeletedSongs();
      }
    } catch (_) {
      // Corrupt index - start fresh but keep any orphaned files.
    }
  }

  Future<void> _loadPlaylists() async {
    _playlists.clear();
    _deletedPlaylistsAt.clear();
    if (_playlistsFile == null || !await _playlistsFile!.exists()) return;
    try {
      final decoded = jsonDecode(await _playlistsFile!.readAsString());
      if (decoded is List) {
        // Legacy format: a bare array of playlists.
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            _playlists.add(Playlist.fromJson(item));
          }
        }
      } else if (decoded is Map<String, dynamic>) {
        for (final item in decoded['playlists'] as List? ?? []) {
          if (item is Map<String, dynamic>) {
            _playlists.add(Playlist.fromJson(item));
          }
        }
        final deleted = decoded['deleted'];
        if (deleted is Map) {
          deleted.forEach((key, value) {
            final at = DateTime.tryParse(value.toString());
            if (at != null) _deletedPlaylistsAt[key.toString()] = at;
          });
        }
      }
    } catch (_) {
      // Corrupt playlists file — start fresh.
    }
  }

  Future<void> _saveIndex() async {
    await _indexFile!.writeAsString(
      jsonEncode({
        'songs': _songs.map((s) => s.toJson()).toList(),
        'deleted': {
          for (final e in _deletedSongsAt.entries)
            e.key: e.value.toIso8601String(),
        },
        'deleted_checksums': {
          for (final e in _deletedChecksumsAt.entries)
            e.key: e.value.toIso8601String(),
        },
      }),
    );
  }

  Future<void> _savePlaylists() async {
    await _playlistsFile!.writeAsString(jsonEncode({
      'playlists': _playlists.map((pl) => pl.toJson()).toList(),
      'deleted': {
        for (final e in _deletedPlaylistsAt.entries)
          e.key: e.value.toIso8601String(),
      },
    }));
  }

  static Future<String> checksum(File file) async {
    final sink = _DigestCapture();
    final checksum = crypto.md5.startChunkedConversion(sink);
    await file.openRead().forEach(checksum.add);
    checksum.close();
    return sink.value!.toString();
  }

  Song? findById(String id) => _songsById[id];

  bool hasChecksum(String checksum) => _checksums.contains(checksum);

  /// Copy externally picked files into the library. Deduplicates by checksum.
  /// Returns the songs that were actually added.
  Future<List<Song>> addLocalFiles(List<File> files) async {
    final added = <Song>[];
    for (final file in files) {
      if (!await file.exists()) continue;
      final sum = await checksum(file);
      if (hasChecksum(sum)) continue; // already have it

      final id = const Uuid().v4();
      final ext = p.extension(file.path).isEmpty ? '.mp3' : p.extension(file.path);
      final fileName = '$id$ext';
      await file.copy(p.join(_libraryDir!.path, fileName));

      final song = Song(
        id: id,
        title: _titleFromName(p.basenameWithoutExtension(file.path)),
        fileName: fileName,
        size: await file.length(),
        checksum: sum,
        sourceDeviceId: null,
        addedAt: DateTime.now(),
      );
      _songs.add(song);
      _indexSong(song);
      _deletedSongsAt.remove(id);
      _deletedChecksumsAt.remove(sum);
      added.add(song);
    }
    if (added.isNotEmpty) {
      await _saveIndex();
      notifyListeners();
    }
    return added;
  }

  /// Called when a file arrives from a peer. Moves the fully-downloaded temp
  /// file into the library and records it with the peer as [sourceDeviceId].
  /// Returns null if the song was marked deleted while transfer was in-flight.
  Future<Song?> addReceivedSong({
    required String id,
    required String title,
    required String fileName,
    required int size,
    required String checksum,
    required String sourceDeviceId,
    String? artwork,
  }) async {
    final tmp = incomingFile(id);
    if (isSongDeleted(id, checksum)) {
      debugPrint(
          '[library] Discarding incoming song $id ($checksum): already marked deleted');
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      return null;
    }

    final ext = p.extension(fileName);
    final finalName = '$id$ext';
    await tmp.rename(p.join(_libraryDir!.path, finalName));

    final song = Song(
      id: id,
      title: title.isEmpty ? _titleFromName(fileName) : title,
      fileName: finalName,
      size: size,
      checksum: checksum,
      sourceDeviceId: sourceDeviceId,
      artwork: artwork,
      addedAt: DateTime.now(),
    );
    final existingIdx =
        _songs.indexWhere((s) => s.id == id || s.checksum == checksum);
    if (existingIdx >= 0) {
      final existing = _songs[existingIdx];
      if (existing.sourceDeviceId == null) {
        // This song was downloaded or added locally on this device.
        // Preserve local ownership (sourceDeviceId == null) and discard duplicate.
        if (await tmp.exists()) {
          try {
            await tmp.delete();
          } catch (_) {}
        }
        return existing;
      }
      _unindexSong(existing);
      _songs[existingIdx] = song;
    } else {
      _songs.add(song);
    }
    _indexSong(song);
    await _saveIndex();
    notifyListeners();
    return song;
  }

  /// Add a single externally-downloaded audio file (e.g. scraped from YouTube)
  /// with an explicit [title] and optional base64 [artwork]. Deduplicates by
  /// checksum. Returns the added song, or `null` if it is already in the
  /// library. The caller is responsible for broadcasting the song to peers.
  Future<Song?> addScrapedFile(
    File file, {
    required String title,
    String? artwork,
  }) async {
    if (!await file.exists()) return null;
    final sum = await checksum(file);
    if (hasChecksum(sum)) return null; // already have it

    final id = const Uuid().v4();
    final ext =
        p.extension(file.path).isEmpty ? '.mp3' : p.extension(file.path);
    final fileName = '$id$ext';
    await file.copy(p.join(_libraryDir!.path, fileName));

    final song = Song(
      id: id,
      title: title.trim().isEmpty
          ? _titleFromName(p.basenameWithoutExtension(file.path))
          : title.trim(),
      fileName: fileName,
      size: await file.length(),
      checksum: sum,
      sourceDeviceId: null,
      artwork: artwork,
      addedAt: DateTime.now(),
    );
    _songs.add(song);
    _indexSong(song);
    _deletedSongsAt.remove(id);
    _deletedChecksumsAt.remove(sum);
    await _saveIndex();
    notifyListeners();
    return song;
  }

  Future<void> removeSong(String id) async {
    final song = findById(id);
    if (song != null) {
      recordSongDeleted(id, checksum: song.checksum);
      _songs.remove(song);
      _unindexSong(song);
      final f = songFile(song);
      if (await f.exists()) await f.delete();
      _stripSongFromPlaylists(id);
    } else {
      recordSongDeleted(id);
    }
    await _saveIndex();
    await _savePlaylists();
    notifyListeners();
  }

  /// The heart of the "un-pair removes shared songs" rule:
  /// deletes every song that was received from [sourceDeviceId].
  Future<int> removeAllFromSource(String sourceDeviceId) async {
    final toRemove = _songs.where((s) => s.sourceDeviceId == sourceDeviceId).toList();
    if (toRemove.isEmpty) return 0;
    for (final song in toRemove) {
      _songs.remove(song);
      _unindexSong(song);
      final f = songFile(song);
      if (await f.exists()) await f.delete();
      _stripSongFromPlaylists(song.id);
    }
    await _saveIndex();
    await _savePlaylists();
    notifyListeners();
    return toRemove.length;
  }

  // ---------- playlists ----------

  Playlist? findPlaylist(String id) {
    for (final pl in _playlists) {
      if (pl.id == id) return pl;
    }
    return null;
  }

  Future<Playlist> createPlaylist(String name) async {
    final pl = Playlist(
      id: const Uuid().v4(),
      name: name.trim().isEmpty ? 'Playlist' : name.trim(),
      songIds: [],
      createdAt: DateTime.now(),
    );
    _playlists.add(pl);
    await _savePlaylists();
    notifyListeners();
    return pl;
  }

  /// Delete [id] and record a deletion tombstone so the removal propagates to
  /// peers (even ones that were offline). Returns the deletion time, or null
  /// if the playlist did not exist.
  Future<DateTime?> deletePlaylist(String id) async {
    if (!_playlists.any((pl) => pl.id == id)) return null;
    _playlists.removeWhere((pl) => pl.id == id);
    final at = DateTime.now();
    _deletedPlaylistsAt[id] = at;
    _pruneTombstones();
    await _savePlaylists();
    notifyListeners();
    return at;
  }

  /// Merge playlists + deletion tombstones received from a peer ("newest edit
  /// wins"). Returns the local playlists that are NEWER than the peer's copy
  /// so the caller can broadcast them back (echo) and converge. A playlist
  /// whose local copy is newer than a deletion tombstone survives; otherwise
  /// the tombstone wins and the local copy is removed.
  Future<List<Playlist>> mergeRemotePlaylists(
    List<Playlist> incoming,
    Map<String, DateTime> deleted,
  ) async {
    final echo = <Playlist>[];
    var changed = false;

    // Deletions: a tombstone wins unless the local copy is strictly newer.
    deleted.forEach((id, at) {
      final local = findPlaylist(id);
      if (local == null) return;
      if (!local.updatedAt.isAfter(at)) {
        _playlists.removeWhere((pl) => pl.id == id);
        _deletedPlaylistsAt[id] = at;
        changed = true;
      }
    });

    // Upserts: newest copy wins; older local copies get echoed back. A playlist
    // we deleted (tombstone) is not resurrected unless the incoming copy is
    // NEWER than our deletion.
    for (final pl in incoming) {
      final tombAt = _deletedPlaylistsAt[pl.id];
      if (tombAt != null && !pl.updatedAt.isAfter(tombAt)) {
        continue;
      }
      final local = findPlaylist(pl.id);
      if (local == null) {
        _playlists.add(pl);
        changed = true;
      } else if (pl.updatedAt.isAfter(local.updatedAt)) {
        final idx = _playlists.indexWhere((p) => p.id == pl.id);
        _playlists[idx] = pl;
        changed = true;
      } else if (pl.updatedAt.isBefore(local.updatedAt)) {
        echo.add(local);
      }
    }

    if (changed) {
      _pruneTombstones();
      await _savePlaylists();
      notifyListeners();
    }
    return echo;
  }

  /// Cap the tombstone list (drop the oldest entries) so it cannot grow
  /// unbounded across a long-lived library.
  void _pruneTombstones() {
    if (_deletedPlaylistsAt.length <= 200) return;
    final sorted = _deletedPlaylistsAt.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (final e in sorted.take(_deletedPlaylistsAt.length - 200)) {
      _deletedPlaylistsAt.remove(e.key);
    }
  }

  Future<void> renamePlaylist(String id, String name) async {
    final idx = _playlists.indexWhere((pl) => pl.id == id);
    if (idx == -1) return;
    final cleaned = name.trim();
    if (cleaned.isEmpty) return;
    _playlists[idx] =
        _playlists[idx].copyWith(name: cleaned, updatedAt: DateTime.now());
    await _savePlaylists();
    notifyListeners();
  }

  /// Add [songId] to [playlistId] (no duplicates). Returns true if added.
  Future<bool> addSongToPlaylist(String playlistId, String songId) async {
    final idx = _playlists.indexWhere((pl) => pl.id == playlistId);
    if (idx == -1) return false;
    if (_playlists[idx].songIds.contains(songId)) return false;
    final ids = [..._playlists[idx].songIds, songId];
    _playlists[idx] =
        _playlists[idx].copyWith(songIds: ids, updatedAt: DateTime.now());
    await _savePlaylists();
    notifyListeners();
    return true;
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    final idx = _playlists.indexWhere((pl) => pl.id == playlistId);
    if (idx == -1) return;
    final ids = _playlists[idx].songIds.where((id) => id != songId).toList();
    _playlists[idx] =
        _playlists[idx].copyWith(songIds: ids, updatedAt: DateTime.now());
    await _savePlaylists();
    notifyListeners();
  }

  /// Replace a playlist's ordered song list wholesale (used for reordering).
  Future<void> setPlaylistSongIds(
      String playlistId, List<String> songIds) async {
    final idx = _playlists.indexWhere((pl) => pl.id == playlistId);
    if (idx == -1) return;
    _playlists[idx] = _playlists[idx]
        .copyWith(songIds: List.of(songIds), updatedAt: DateTime.now());
    await _savePlaylists();
    notifyListeners();
  }

  void _stripSongFromPlaylists(String songId) {
    var changed = false;
    for (var i = 0; i < _playlists.length; i++) {
      if (_playlists[i].songIds.contains(songId)) {
        final ids = _playlists[i].songIds.where((id) => id != songId).toList();
        _playlists[i] = _playlists[i].copyWith(songIds: ids);
        changed = true;
      }
    }
    if (changed) _savePlaylists();
  }

  String _titleFromName(String base) {
    // "Song - Artist" -> keep as is; otherwise title-case the filename.
    final cleaned = base.replaceAll(RegExp(r'[_]+'), ' ').trim();
    return cleaned.isEmpty ? 'Unknown Track' : cleaned;
  }
}

/// Captures the digest produced by a chunked hash conversion.
class _DigestCapture implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}
