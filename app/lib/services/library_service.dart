import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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

  /// Song IDs whose audio file is known to exist on disk. Cached so that
  /// hot paths (manifest matching during sync) avoid per-song `existsSync()`
  /// syscalls, which caused severe UI lag with large libraries.
  final Set<String> _filesOnDisk = {};
  List<Song> get songs => List.unmodifiable(_songs);

  void _rebuildIndexMaps() {
    _songsById.clear();
    _checksums.clear();
    for (final s in _songs) {
      _songsById[s.id] = s;
      _checksums.add(s.checksum);
    }
  }

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
    // One-time disk verification to seed the existence cache.
    for (final s in _songs) {
      try {
        final f = File(p.join(_libraryDir!.path, s.fileName));
        if (await f.exists() && await f.length() > 0) {
          _filesOnDisk.add(s.id);
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  Directory get libraryDir => _libraryDir!;

  File songFile(Song song) => File(p.join(_libraryDir!.path, song.fileName));

  bool hasSongFile(Song song) => _filesOnDisk.contains(song.id);

  /// Force a real disk check for [song] and refresh the cache. Use when the
  /// cached answer matters (e.g. before sending a file to a peer).
  Future<bool> verifySongFile(Song song) async {
    try {
      final file = songFile(song);
      final ok = await file.exists() && await file.length() > 0;
      if (ok) {
        _filesOnDisk.add(song.id);
      } else {
        _filesOnDisk.remove(song.id);
      }
      return ok;
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

  Timer? _saveIndexDebounce;
  Timer? _notifyDebounce;

  /// Runs in a background isolate: serialises the whole song list to JSON.
  static String _encodeSongsJson(List<Song> songs) =>
      jsonEncode(songs.map((s) => s.toJson()).toList());

  Future<void> _saveIndex() async {
    _saveIndexDebounce?.cancel();
    _saveIndexDebounce = null;
    if (_indexFile == null) return;
    try {
      final jsonStr = await compute(_encodeSongsJson, _songs);
      await _indexFile!.writeAsString(jsonStr);
    } catch (e) {
      debugPrint('[library] error saving index: $e');
    }
  }

  void _scheduleSaveIndex() {
    _saveIndexDebounce?.cancel();
    _saveIndexDebounce = Timer(const Duration(milliseconds: 1500), () {
      _saveIndex();
    });
  }

  Future<void> flushSaveIndex() async {
    if (_saveIndexDebounce != null) {
      await _saveIndex();
    }
  }

  void _scheduleNotify() {
    if (_notifyDebounce?.isActive ?? false) return;
    _notifyDebounce = Timer(const Duration(milliseconds: 250), () {
      _notifyDebounce = null;
      notifyListeners();
    });
  }

  void flushNotify() {
    _notifyDebounce?.cancel();
    _notifyDebounce = null;
    notifyListeners();
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

  /// Synchronously computes MD5 hash from disk in a background isolate.
  static String checksumPath(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return '';
    final sink = _DigestCapture();
    final checksum = crypto.md5.startChunkedConversion(sink);
    final raf = file.openSync(mode: FileMode.read);
    try {
      while (true) {
        final chunk = raf.readSync(64 * 1024);
        if (chunk.isEmpty) break;
        checksum.add(chunk);
      }
    } finally {
      raf.closeSync();
    }
    checksum.close();
    return sink.value?.toString() ?? '';
  }

  // ---- Long-lived hash worker ----
  //
  // Verification MD5s used to spawn a FRESH isolate per song (compute). With
  // several songs finishing back-to-back after a transfer, the repeated
  // isolate spawns plus sustained hashing saturated a core on phones and
  // starved the UI/raster threads — the "lag that persists after transfer".
  // One persistent worker processes the queue serially and yields briefly
  // between songs so the UI keeps core time.
  static Isolate? _hashIsolate;
  static SendPort? _hashSendPort;
  static final Map<int, Completer<String>> _hashJobs = {};
  static int _hashJobSeq = 0;

  /// Offloaded to a background worker to ensure zero UI blockage even for
  /// large multi-megabyte audio files.
  static Future<String> checksum(File file) async {
    try {
      return await _checksumViaWorker(file.path);
    } catch (_) {
      // Worker unavailable (e.g. test env) — fall back to a one-shot isolate.
      return await compute(checksumPath, file.path);
    }
  }

  static Future<String> _checksumViaWorker(String path) async {
    await _ensureHashWorker();
    final seq = _hashJobSeq++;
    final completer = Completer<String>();
    _hashJobs[seq] = completer;
    _hashSendPort!.send([seq, path]);
    return completer.future;
  }

  static Future<void> _ensureHashWorker() async {
    if (_hashSendPort != null) return;
    final ready = Completer<SendPort>();
    // One port handles BOTH the worker handshake (first message = its
    // reply SendPort) and all subsequent [seq, result] job replies.
    final replyPort = ReceivePort();
    _hashIsolate = await Isolate.spawn(_hashWorkerMain, replyPort.sendPort);
    replyPort.listen((msg) {
      if (msg is SendPort) {
        if (!ready.isCompleted) ready.complete(msg);
        return;
      }
      if (msg is List && msg.length == 2) {
        final seq = msg[0] as int;
        final completer = _hashJobs.remove(seq);
        if (completer != null) {
          final value = msg[1];
          if (value is String) {
            completer.complete(value);
          } else {
            completer.completeError(value as Object);
          }
        }
      }
    });
    _hashSendPort = await ready.future;
  }

  /// Worker entry point: receives [seq, path] jobs, replies [seq, md5].
  /// Yields ~16ms between jobs so UI/raster threads keep core time.
  static void _hashWorkerMain(SendPort ready) {
    // [ready] points back at the main isolate's reply port — results MUST be
    // sent there (sending on our own job port would loop back to ourselves).
    final port = ReceivePort();
    ready.send(port.sendPort);
    port.listen((job) async {
      final seq = job[0] as int;
      final path = job[1] as String;
      Object result;
      try {
        result = checksumPath(path);
      } catch (e) {
        result = e;
      }
      // Yield between songs: lets the UI thread schedule frames even when a
      // batch of verifications is queued back-to-back.
      await Future<void>.delayed(const Duration(milliseconds: 16));
      ready.send([seq, result]);
    });
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
      _filesOnDisk.add(id);
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
  Future<Song> addReceivedSong({
    required String id,
    required String title,
    required String fileName,
    required int size,
    required String checksum,
    required String sourceDeviceId,
    String? artwork,
  }) async {
    final tmp = incomingFile(id);
    final ext = p.extension(fileName);
    final finalName = '$id$ext';
    final targetPath = p.join(_libraryDir!.path, finalName);
    final targetFile = File(targetPath);
    var fileOnDisk = false;
    if (await tmp.exists()) {
      try {
        if (await targetFile.exists()) {
          await targetFile.delete();
        }
        await tmp.rename(targetPath);
        fileOnDisk = true;
      } catch (_) {
        // Fallback for cross-device/partition moves (EXDEV) or Windows locks
        try {
          await tmp.copy(targetPath);
          if (await tmp.exists()) await tmp.delete();
          fileOnDisk = true;
        } catch (_) {}
      }
    }

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
      _unindexSong(existing);
      _songs[existingIdx] = song;
    } else {
      _songs.add(song);
    }
    _indexSong(song);
    // Only mark the file as present if it actually landed on disk — callers
    // may register metadata for a file that is still missing (recovery path).
    if (fileOnDisk || await targetFile.exists()) {
      _filesOnDisk.add(song.id);
    } else {
      _filesOnDisk.remove(song.id);
    }
    _scheduleSaveIndex();
    _scheduleNotify();
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
    _filesOnDisk.add(id);
    await _saveIndex();
    notifyListeners();
    return song;
  }

  Future<void> removeSong(String id) async {
    final song = findById(id);
    if (song == null) return;
    _songs.remove(song);
    _unindexSong(song);
    _filesOnDisk.remove(id);
    final f = songFile(song);
    if (await f.exists()) await f.delete();
    _stripSongFromPlaylists(id);
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
      _filesOnDisk.remove(song.id);
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

  @override
  void dispose() {
    _saveIndexDebounce?.cancel();
    _notifyDebounce?.cancel();
    super.dispose();
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
