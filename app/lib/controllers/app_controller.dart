import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../models/playlist.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/identity_service.dart';
import '../services/library_profile.dart';
import '../services/library_service.dart';
import '../services/lyrics_service.dart';
import '../services/player_service.dart';
import '../services/recommendation_service.dart';
import '../services/stream_cache_manager.dart';
import '../services/youtube_search_service.dart';
import '../services/youtube_service.dart';

/// Central state + orchestration for the whole app.
///
/// Owns the services and translates player / library events into a simple
/// state surface that the widgets render:
///   - the music library and favorites
///   - playlists and queue ordering
///   - playback state and streaming
class AppController extends ChangeNotifier with WidgetsBindingObserver {
  final IdentityService identity;
  final LibraryService library;
  final PlayerService player;
  final YoutubeService youtube;

  AppController({
    required this.identity,
    required this.library,
    required this.player,
    required this.youtube,
  });

  List<Song> get songs => library.songs;

  Set<String> get favoriteSongIds => identity.favoriteSongIds;
  bool isFavorite(String songId) => identity.isFavorite(songId);

  List<Song>? _cachedFavoriteSongs;
  List<Song>? _lastSortInput;
  SortOption? _lastSortOption;
  List<Song>? _lastSortResult;

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    _cachedFavoriteSongs = null;
    _lastSortInput = null;
    _lastSortResult = null;
    super.notifyListeners();
  }

  List<Song> get favoriteSongs {
    if (_cachedFavoriteSongs != null) return _cachedFavoriteSongs!;
    final List<Song> result = [];
    final seen = <String>{};
    for (final s in library.songs) {
      if (identity.isFavorite(s.id)) {
        result.add(s);
        seen.add(s.id);
      }
    }
    for (final s in identity.favoriteOnlineSongs.values) {
      if (!seen.contains(s.id) && identity.isFavorite(s.id)) {
        result.add(s);
        seen.add(s.id);
      }
    }
    for (final id in identity.favoriteSongIds) {
      if (!seen.contains(id) &&
          (id.startsWith('stream_') || id.startsWith('yt_'))) {
        final videoId = RecommendationService.extractVideoId(id) ??
            id.replaceFirst('stream_', '');
        final song = Song(
          id: id,
          title: 'Online Stream ($videoId)',
          fileName: 'stream_$videoId.m4a',
          size: 0,
          checksum: id,
          sourceDeviceId: 'stream',
          addedAt: DateTime.now(),
        );
        result.add(song);
        seen.add(id);
      }
    }
    _cachedFavoriteSongs = result;
    return result;
  }

  Song? findSongById(String id) {
    return library.findById(id) ?? identity.findOnlineSong(id);
  }

  Future<void> toggleFavorite(String songId, {Song? song}) async {
    final resolvedSong = song ??
        (player.currentSong?.id == songId
            ? player.currentSong
            : findSongById(songId));
    await identity.toggleFavorite(songId, song: resolvedSong);
    notifyListeners();
  }

  SortOption get sortOption => identity.sortOption;
  Future<void> setSortOption(SortOption option) async {
    await identity.setSortOption(option);
    notifyListeners();
  }

  List<Song> getSortedSongs(List<Song> songList) {
    if (identical(songList, _lastSortInput) &&
        identity.sortOption == _lastSortOption &&
        _lastSortResult != null) {
      return _lastSortResult!;
    }
    final list = List<Song>.from(songList);
    switch (identity.sortOption) {
      case SortOption.title:
        list.sort((a, b) => a.lowerTitle.compareTo(b.lowerTitle));
        break;
      case SortOption.size:
        list.sort((a, b) => b.size.compareTo(a.size));
        break;
      case SortOption.dateAdded:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
        break;
    }
    _lastSortInput = songList;
    _lastSortOption = identity.sortOption;
    _lastSortResult = list;
    return list;
  }

  bool _closing = false;

  final _messages = StreamController<String>.broadcast();
  Stream<String> get messages => _messages.stream;

  final List<StreamSubscription> _subs = [];
  final List<VoidCallback> _removeNotifierListeners = [];

  bool _isLifecycleObserved = false;
  int _lastBackgroundFlushEpoch = 0;

  // ---------- lifecycle ----------

  Future<void> init() async {
    await library.init();
    await player.init();

    _removeNotifierListeners.addAll([
      () => library.removeListener(notifyListeners),
      () => player.removeListener(notifyListeners),
      () => identity.removeListener(notifyListeners),
    ]);
    library.addListener(notifyListeners);
    player.addListener(notifyListeners);
    identity.addListener(notifyListeners);

    if (!_isLifecycleObserved) {
      try {
        WidgetsBinding.instance.addObserver(this);
        _isLifecycleObserved = true;
      } catch (_) {}
    }

    notifyListeners();
  }

  Future<int> forceSync() async {
    notifyListeners();
    return 0;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastBackgroundFlushEpoch < 1500) {
        debugPrint('[app] Debouncing rapid background save hook');
        return;
      }
      _lastBackgroundFlushEpoch = now;
      debugPrint('[app] app backgrounded: flushing pending saves');
      library.flushSaveIndex();
      ArtworkPalette.compactMemory();
      LyricsService.compactMemory();
      PaintingBinding.instance.imageCache.clearLiveImages();
      PaintingBinding.instance.imageCache.clear();
      LibraryService.killHashWorker();
      if (!player.playing && !player.isLoadingTrack && !player.isAdvancing) {
        YouTubeSearchService.dispose();
      }
    } else if (state == AppLifecycleState.detached) {
      debugPrint('[app] app detached: executing full cleanup');
      unawaited(disposeAll());
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    debugPrint('[app] app exit requested: tearing down all resources');
    await disposeAll();
    return AppExitResponse.exit;
  }

  Future<void> disposeAll() async {
    if (_closing) return;
    _closing = true;
    if (_isLifecycleObserved) {
      try {
        WidgetsBinding.instance.removeObserver(this);
        _isLifecycleObserved = false;
      } catch (_) {}
    }
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final remove in _removeNotifierListeners) {
      remove();
    }
    _removeNotifierListeners.clear();
    // Persist any queued library index changes before teardown; the debounced
    // saver would otherwise be cancelled with the write still pending.
    await library.flushSaveIndex();
    player.dispose();
    library.dispose();
    LibraryService.killHashWorker();
    YouTubeSearchService.dispose();
    StreamCacheManager.dispose();
    _messages.close();
    super.dispose();
  }

  // ---------- library ----------

  Future<void> addFilesFromPicker() async {
    final files = await FilePicker.pickFiles(
      type: FileType.audio,
    );
    if (files.isEmpty) return;
    final picked = files
        .map((f) => File(f.path ?? ''))
        .where((f) => f.existsSync())
        .toList();
    if (picked.isEmpty) return;
    final added = await library.addLocalFiles(picked);
    if (added.isNotEmpty) {
      _postMessage('Added ${added.length} song(s).');
    }
  }

  Future<void> addDroppedFiles(List<File> files) async {
    if (files.isEmpty) return;
    final added = await library.addLocalFiles(files);
    if (added.isNotEmpty) {
      _postMessage('Added ${added.length} dropped song(s).');
    }
  }

  // ---------- playlists ----------

  List<Playlist> get playlists => library.playlists;

  Future<Playlist> createPlaylist(String name) async {
    return await library.createPlaylist(name);
  }

  Future<void> deletePlaylist(String id) async {
    await library.deletePlaylist(id);
  }

  Future<void> renamePlaylist(String id, String name) async {
    await library.renamePlaylist(id, name);
  }

  Future<bool> addSongToPlaylist(String playlistId, String songId,
      {Song? song}) async {
    final resolved = song ?? findSongById(songId);
    if (resolved != null &&
        (resolved.sourceDeviceId == 'stream' ||
            resolved.id.startsWith('stream_'))) {
      await identity.registerOnlineSong(resolved);
    }
    return await library.addSongToPlaylist(playlistId, songId);
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    await library.removeSongFromPlaylist(playlistId, songId);
  }

  Future<void> reorderPlaylist(String playlistId, List<String> songIds) async {
    await library.setPlaylistSongIds(playlistId, songIds);
  }

  Future<void> exportPlaylistToM3u(Playlist playlist) async {
    final buffer = StringBuffer();
    buffer.writeln('#EXTM3U');
    buffer.writeln('#PLAYLIST:${playlist.name}');
    for (final songId in playlist.songIds) {
      final song = findSongById(songId);
      if (song == null) continue;
      buffer.writeln('#EXTINF:-1,${song.title}');
      if (song.sourceDeviceId == 'stream' || song.id.startsWith('stream_')) {
        final videoId = song.id.replaceFirst('stream_', '');
        buffer.writeln('https://www.youtube.com/watch?v=$videoId');
      } else {
        // Portable relative file reference
        buffer.writeln(song.fileName);
      }
    }

    final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
    final safeName =
        playlist.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final fileName = safeName.isEmpty ? 'playlist.m3u8' : '$safeName.m3u8';
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Export Playlist',
        fileName: fileName,
        bytes: bytes,
      );
      if (uri != null) {
        _postMessage('Exported "${playlist.name}" successfully.');
      }
    } catch (e) {
      debugPrint('[controller] Error exporting playlist: $e');
      _postMessage('Failed to export playlist.');
    }
  }

  Future<void> importPlaylistFromM3u() async {
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['m3u', 'm3u8'],
        dialogTitle: 'Import Playlist',
      );
      if (picked.isEmpty) return;
      final filePath = picked.first.path;
      if (filePath == null) return;
      final file = File(filePath);
      if (!await file.exists()) return;

      final content = await file.readAsString();
      final lines = content.split(RegExp(r'\r?\n'));
      final songIds = <String>[];
      final m3uDir = p.dirname(filePath);
      String playlistName = p.basenameWithoutExtension(file.path);

      // Collect entries: pairs of (extinf, targetLine)
      final rawEntries = <({String extinf, String target})>[];

      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        if (line.startsWith('#PLAYLIST:')) {
          final name = line.replaceFirst('#PLAYLIST:', '').trim();
          if (name.isNotEmpty) playlistName = name;
        } else if (line.startsWith('#EXTINF:')) {
          var targetLine = '';
          for (var j = i + 1; j < lines.length; j++) {
            final next = lines[j].trim();
            if (next.isNotEmpty && !next.startsWith('#')) {
              targetLine = next;
              i = j;
              break;
            }
          }
          rawEntries.add((extinf: line, target: targetLine));
        } else if (!line.startsWith('#')) {
          rawEntries.add((extinf: '', target: line));
        }
      }

      if (rawEntries.isEmpty) {
        _postMessage('No valid entries found in $playlistName');
        return;
      }

      // Preserve original track order by allocating indexed slots for all raw entries
      final resolvedSongs = List<Song?>.filled(rawEntries.length, null);
      final unmatched = <({int index, String extinf, String target})>[];
      final newOnlineSongs = <Song>[];

      // Phase 1: Fast local and direct stream URL matching (Zero network queries)
      for (var i = 0; i < rawEntries.length; i++) {
        final entry = rawEntries[i];
        final directSong = await _matchDirectOrLocalSong(
          entry.extinf,
          entry.target,
          m3uDir: m3uDir,
        );
        if (directSong != null) {
          resolvedSongs[i] = directSong;
          if (directSong.sourceDeviceId == 'stream' ||
              directSong.id.startsWith('stream_')) {
            newOnlineSongs.add(directSong);
          }
        } else {
          unmatched.add((index: i, extinf: entry.extinf, target: entry.target));
        }
      }

      // Phase 2: Bandwidth-safe throttled online resolution for missing tracks
      // Cap at 25 tracks per import to guarantee bandwidth and rate limits are respected
      if (unmatched.isNotEmpty) {
        final resolveBatch = unmatched.take(25).toList();
        for (var idx = 0; idx < resolveBatch.length; idx++) {
          final item = resolveBatch[idx];
          final query = _extractSearchQuery(item.extinf, item.target);
          if (query.isNotEmpty) {
            final onlineSong = await _searchAndResolveOnlineTrack(query);
            if (onlineSong != null) {
              resolvedSongs[item.index] = onlineSong;
              newOnlineSongs.add(onlineSong);
            }
            // Rate limiting: 250ms delay between lightweight text search queries
            if (idx < resolveBatch.length - 1) {
              await Future.delayed(const Duration(milliseconds: 250));
            }
          }
        }
      }

      if (newOnlineSongs.isNotEmpty) {
        await identity.registerOnlineSongs(newOnlineSongs);
      }

      // Assemble final songIds preserving exact file sequence and avoiding duplicates
      for (final song in resolvedSongs) {
        if (song != null && !songIds.contains(song.id)) {
          songIds.add(song.id);
        }
      }

      if (songIds.isEmpty) {
        _postMessage('No matching songs found in $playlistName');
        return;
      }

      final created = await library.createPlaylist(playlistName);
      await library.setPlaylistSongIds(created.id, songIds);
      final count = songIds.length;
      _postMessage('Imported "$playlistName" ($count track${count == 1 ? '' : 's'})');
    } catch (e) {
      debugPrint('[controller] Error importing playlist: $e');
      _postMessage('Failed to import playlist.');
    }
  }

  Future<Song?> _matchDirectOrLocalSong(
    String extinf,
    String pathOrUrl, {
    String? m3uDir,
  }) async {
    // 1. Direct stream URL (Zero network requests)
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      final videoId = RecommendationService.extractVideoId(pathOrUrl);
      if (videoId != null) {
        final streamId = 'stream_$videoId';
        final existing = findSongById(streamId);
        if (existing != null) return existing;
        String title = videoId;
        if (extinf.startsWith('#EXTINF:')) {
          final commaIdx = extinf.indexOf(',');
          if (commaIdx != -1) {
            final raw = extinf.substring(commaIdx + 1).trim();
            if (raw.isNotEmpty) title = raw;
          }
        }
        return Song(
          id: streamId,
          title: title,
          fileName: '$title [$videoId].m4a',
          size: 200 * 16000,
          checksum: streamId,
          sourceDeviceId: 'stream',
          addedAt: DateTime.now(),
        );
      }
    }

    if (pathOrUrl.isNotEmpty) {
      // 2. Exact match in local library
      final normalizedPath = p.normalize(pathOrUrl).toLowerCase();
      final base = p.basename(pathOrUrl).toLowerCase();
      for (final s in library.songs) {
        final songFilePath =
            p.normalize(library.songFile(s).path).toLowerCase();
        if (songFilePath == normalizedPath || p.basename(songFilePath) == base) {
          return s;
        }
      }

      // 3. Match relative to M3U file directory if provided
      if (m3uDir != null && !p.isAbsolute(pathOrUrl)) {
        final candidate = File(p.join(m3uDir, pathOrUrl));
        if (await candidate.exists()) {
          final added = await library.addLocalFiles([candidate]);
          if (added.isNotEmpty) return added.first;
        }
      }

      // 4. Match absolute disk path
      final diskFile = File(pathOrUrl);
      if (await diskFile.exists()) {
        final added = await library.addLocalFiles([diskFile]);
        if (added.isNotEmpty) return added.first;
      }
    }

    // 5. Match by title against existing library or known online songs
    String? titleCandidate;
    if (extinf.startsWith('#EXTINF:')) {
      final commaIdx = extinf.indexOf(',');
      if (commaIdx != -1) {
        titleCandidate = extinf.substring(commaIdx + 1).trim();
      }
    }
    if (titleCandidate != null && titleCandidate.isNotEmpty) {
      final raw = titleCandidate.toLowerCase();
      for (final s in library.songs) {
        if (s.lowerTitle == raw || s.title.toLowerCase() == raw) {
          return s;
        }
      }
      for (final s in identity.knownOnlineSongs.values) {
        if (s.lowerTitle == raw || s.title.toLowerCase() == raw) {
          return s;
        }
      }
    }

    return null;
  }

  String _extractSearchQuery(String extinf, String pathOrUrl) {
    if (extinf.startsWith('#EXTINF:')) {
      final commaIdx = extinf.indexOf(',');
      if (commaIdx != -1) {
        final raw = extinf.substring(commaIdx + 1).trim();
        if (raw.isNotEmpty) return raw;
      }
    }
    if (pathOrUrl.isNotEmpty &&
        !pathOrUrl.startsWith('http://') &&
        !pathOrUrl.startsWith('https://')) {
      final base = p
          .basenameWithoutExtension(pathOrUrl)
          .replaceAll(RegExp(r'[_]+'), ' ')
          .trim();
      if (base.isNotEmpty) return base;
    }
    return '';
  }

  Future<Song?> _searchAndResolveOnlineTrack(String query) async {
    try {
      final results = await YouTubeSearchService.search(query, limit: 1);
      if (results.isNotEmpty) {
        return results.first.toSong();
      }
    } catch (e) {
      debugPrint('[controller] Online track resolve error for "$query": $e');
    }
    return null;
  }

  // ---------- library profile ----------

  bool _profileImporting = false;
  DownloadCancellation? _profileImportCancel;

  /// True while a library profile import is fetching songs.
  bool get isProfileImporting => _profileImporting;

  /// Stops an in-flight library profile import after the current song.
  void cancelLibraryProfileImport() {
    _profileImportCancel?.cancel();
  }

  /// Writes the portable library profile (link-added songs only) to a file.
  Future<void> exportLibraryProfile() async {
    try {
      final content = LibraryProfile.build(library.songs);
      if (content == null) {
        _postMessage(
          'Nothing to export yet: a profile lists songs added from links, and the library has none.',
        );
        return;
      }
      final now = DateTime.now();
      final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final bytes = Uint8List.fromList(utf8.encode(content));
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Export Library Profile',
        fileName: 'Pear Music Library $date.m3u8',
        bytes: bytes,
      );
      if (uri != null) {
        _postMessage('Exported library profile successfully.');
      }
    } catch (e) {
      debugPrint('[controller] Error exporting library profile: $e');
      _postMessage('Failed to export the library profile.');
    }
  }

  /// Imports a profile file, fetching every listed song into the library one
  /// at a time. Songs already present (same YouTube ID) are skipped so
  /// importing the same profile twice can never duplicate anything.
  Future<({int added, int skipped, int failed, bool cancelled})?>
      importLibraryProfile({
    void Function(String status)? onStatus,
    void Function(int done, int total)? onProgress,
    void Function(int downloadedBytes, int totalBytes)? onBytes,
  }) async {
    if (_profileImporting) {
      _postMessage('A library profile import is already running.');
      return null;
    }
    try {
      onStatus?.call('Choosing a profile file…');
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['m3u', 'm3u8'],
        dialogTitle: 'Import Library Profile',
      );
      if (picked.isEmpty) return null;
      final filePath = picked.first.path;
      if (filePath == null) return null;
      final file = File(filePath);
      if (!await file.exists()) return null;

      onStatus?.call('Reading profile…');
      final entries = LibraryProfile.parse(await file.readAsString());
      if (entries.isEmpty) {
        _postMessage('No link-based songs found in that profile.');
        return null;
      }

      final knownIds = library.songs
          .map(LibraryProfile.videoIdOf)
          .whereType<String>()
          .toSet();
      final todo = <ProfileEntry>[];
      var skipped = 0;
      for (final entry in entries) {
        if (knownIds.add(entry.videoId)) {
          todo.add(entry);
        } else {
          skipped++;
        }
      }
      if (todo.isEmpty) {
        _postMessage(
          'All $skipped song(s) in that profile are already in the library.',
        );
        return (added: 0, skipped: skipped, failed: 0, cancelled: false);
      }

      _profileImporting = true;
      _profileImportCancel = DownloadCancellation();
      final cancel = _profileImportCancel!;
      final isAndroid = !kIsWeb && Platform.isAndroid;
      var added = 0;
      var failed = 0;
      var cancelled = false;
      try {
        for (var i = 0; i < todo.length; i++) {
          if (cancel.isCancelled) {
            cancelled = true;
            break;
          }
          final entry = todo[i];
          final label = entry.title.isEmpty ? entry.videoId : entry.title;
          onProgress?.call(i, todo.length);
          onStatus?.call('Fetching ${i + 1} of ${todo.length}: $label');
          final url = 'https://www.youtube.com/watch?v=${entry.videoId}';
          try {
            final song = await (isAndroid
                ? youtube.scrapeAndAddWithEmbeddedYtDlp(library, url,
                    onProgress: onBytes, cancel: cancel)
                : youtube.scrapeAndAddWithYtDlp(library, url,
                    onProgress: onBytes, cancel: cancel));
            if (cancel.isCancelled) {
              cancelled = true;
              break;
            }
            if (song != null) {
              added++;
            } else {
              skipped++;
            }
          } catch (e) {
            if (cancel.isCancelled) {
              cancelled = true;
              break;
            }
            failed++;
            debugPrint(
                '[controller] Profile import failed for ${entry.videoId}: $e');
          }
        }
      } finally {
        _profileImporting = false;
        _profileImportCancel = null;
      }

      onProgress?.call(todo.length, todo.length);
      _postMessage(
        cancelled
            ? 'Profile import cancelled: $added added, $skipped already had.'
            : 'Profile import finished: $added added, $skipped already had, $failed failed.',
      );
      notifyListeners();
      return (
        added: added,
        skipped: skipped,
        failed: failed,
        cancelled: cancelled,
      );
    } catch (e) {
      debugPrint('[controller] Error importing library profile: $e');
      _postMessage('Failed to import the library profile.');
      return null;
    }
  }

  final Map<String, Future<String?>> _inFlightAddFromLink = {};

  Future<String?> addFromLink(
    String url, {
    YoutubeStatusCallback? onStatus,
    YoutubeProgressCallback? onProgress,
    DownloadCancellation? cancel,
  }) async {
    final existing = _inFlightAddFromLink[url];
    if (existing != null) return existing;

    final future = _addFromLinkInternal(
      url,
      onStatus: onStatus,
      onProgress: onProgress,
      cancel: cancel,
    );
    _inFlightAddFromLink[url] = future;
    try {
      return await future;
    } finally {
      _inFlightAddFromLink.remove(url);
    }
  }

  Future<String?> _addFromLinkInternal(
    String url, {
    YoutubeStatusCallback? onStatus,
    YoutubeProgressCallback? onProgress,
    DownloadCancellation? cancel,
  }) async {
    Song? song;
    Object? error;
    final isAndroid = !kIsWeb && Platform.isAndroid;

    try {
      song = await (isAndroid
              ? youtube.scrapeAndAddWithEmbeddedYtDlp(library, url,
                  onStatus: onStatus, onProgress: onProgress, cancel: cancel)
              : youtube.scrapeAndAddWithYtDlp(library, url,
                  onStatus: onStatus, onProgress: onProgress, cancel: cancel))
          .timeout(const Duration(minutes: 7));
    } catch (e) {
      error = e;
      debugPrint('[pearmusic] yt-dlp download failed: $e');
    }

    if (song == null) {
      if (error is DownloadCancelledException) return 'Cancelled.';
      if (error == null) return 'That track is already in your library.';
      debugPrint('[pearmusic] addFromLink final error: $error');
      return _friendlyDownloadError(error);
    }
    _postMessage('Added "${song.title}".');
    return null;
  }

  Future<List<YouTubeSearchResult>> searchYouTube(String query) {
    return YouTubeSearchService.search(query);
  }

  Future<({Song? song, String? error})> downloadAndGetYouTubeSong(
    YouTubeSearchResult result, {
    YoutubeProgressCallback? onProgress,
    DownloadCancellation? cancel,
  }) async {
    final initialIds = library.songs.map((s) => s.id).toSet();

    final err = await addFromLink(
      result.url,
      onProgress: onProgress,
      cancel: cancel,
    );

    if (err != null && !err.contains('already in your library')) {
      return (song: null, error: err);
    }

    final newSongs = library.songs.where((s) => !initialIds.contains(s.id));
    if (newSongs.isNotEmpty) {
      return (song: newSongs.first, error: null);
    }

    final cleanTitle = result.title.toLowerCase().trim();
    for (final s in library.songs) {
      final sTitle = s.title.toLowerCase().trim();
      if (sTitle == cleanTitle ||
          sTitle.contains(cleanTitle) ||
          cleanTitle.contains(sTitle)) {
        return (song: s, error: null);
      }
    }

    return (
      song: library.songs.isNotEmpty ? library.songs.first : null,
      error: null,
    );
  }

  String _friendlyDownloadError(Object e) {
    if (e is TimeoutException) {
      return 'Download took too long. Try again in a few minutes.';
    }
    final s = e.toString().toLowerCase();
    if (s.contains('not installed')) {
      return 'yt-dlp is not installed on this device. On the PC install it '
          'with: winget install yt-dlp.yt-dlp  (the phone has it built in).';
    }
    if (s.contains('yt-dlp')) {
      return 'yt-dlp could not download this link. Try again, or check your '
          'internet connection.';
    }
    if (s.contains('403') ||
        s.contains('forbidden') ||
        s.contains('sign in to confirm')) {
      return 'YouTube blocked this request (it may ask for verification). '
          'Wait a while and try again.';
    }
    return 'Download failed: $e';
  }

  Future<void> playPlaylist(Playlist playlist) async {
    final songs = [
      for (final id in playlist.songIds)
        if (findSongById(id) != null) findSongById(id)!,
    ];
    if (songs.isEmpty) {
      _postMessage('This playlist is empty.');
      return;
    }
    await player.playSong(
      songs.first,
      queue: songs,
      sourceId: 'playlist:${playlist.id}',
      sourceTitle: playlist.name,
    );
  }

  Future<void> removeSong(Song song) async {
    player.removeSongsFromQueue({song.id});
    await identity.removeFavorite(song.id);
    await library.removeSong(song.id);
    _postMessage('Removed "${song.title}"');
  }

  Future<void> removeSongs(List<Song> songs) async {
    final songIds = songs.map((s) => s.id).toSet();
    player.removeSongsFromQueue(songIds);
    await identity.removeFavorites(songIds);
    await library.removeSongs(songIds);
    _postMessage('Removed ${songs.length} ${songs.length == 1 ? "song" : "songs"}');
    notifyListeners();
  }

  void playNext(Song song) {
    player.playNext(song);
    _postMessage('Playing "${song.title}" next');
  }

  void addToQueue(Song song) {
    player.addToQueue(song);
    _postMessage('Added "${song.title}" to queue');
  }

  void addSongsToQueue(List<Song> songs, {bool playNext = false}) {
    if (songs.isEmpty) return;
    player.addSongsToQueue(songs, playNext: playNext);
    _postMessage('Added ${songs.length} ${songs.length == 1 ? "song" : "songs"} to queue');
  }

  // ---------- settings ----------

  Future<void> updateSynthesizerBar(bool val) async {
    await identity.setSynthesizerBar(val);
    notifyListeners();
  }

  Future<void> updateVisualizerGlow(bool val) async {
    await identity.setVisualizerGlow(val);
    notifyListeners();
  }

  // ---------- playback (delegated) ----------

  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    String? sourceId,
    String? sourceTitle,
  }) =>
      player.playSong(
        song,
        queue: queue ?? getSortedSongs(library.songs),
        sourceId: sourceId ?? (queue != null ? null : 'library'),
        sourceTitle: sourceTitle,
      );
  Future<void> startRadio(Song song) => player.startRadio(song);
  bool get autoplay => player.autoplay;
  void setAutoplay(bool value) {
    player.setAutoplay(value);
    notifyListeners();
  }
  Future<void> saveStreamToLibrary(Song song) async {
    _postMessage('Downloading "${song.title}" to library…');
    final wasFav = isFavorite(song.id);
    final saved = await StreamCacheManager.saveToLibrary(song, library);
    if (saved != null) {
      if (wasFav && !isFavorite(saved.id)) {
        await toggleFavorite(saved.id, song: saved);
      }
      _postMessage('Added "${saved.title}" to library');
      notifyListeners();
    } else {
      _postMessage('Failed to download "${song.title}"');
    }
  }
  Future<void> togglePlayback() => player.toggle();
  Future<void> nextTrack() => player.next(userAction: true);
  Future<void> previousTrack() => player.previous();
  Future<void> toggleLoop() => player.toggleLoop();
  void toggleShuffle() => player.toggleShuffle();
  void reorderQueue(int oldIndex, int newIndex) =>
      player.reorderQueue(oldIndex, newIndex);
  void removeFromQueue(int index) => player.removeFromQueue(index);
  Future<void> seek(Duration d) => player.seek(d);
  Future<void> setVolume(double v) => player.setVolume(v);
  Future<void> setPlaybackSpeed(double speed) => player.setSpeed(speed);


  void _postMessage(String text) {
    if (!_messages.isClosed) _messages.add(text);
  }

  @override
  void dispose() {
    _disposed = true;
    if (_isLifecycleObserved) {
      try {
        WidgetsBinding.instance.removeObserver(this);
        _isLifecycleObserved = false;
      } catch (_) {}
    }
    for (final remove in _removeNotifierListeners) {
      remove();
    }
    _removeNotifierListeners.clear();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _messages.close();
    super.dispose();
  }
}
