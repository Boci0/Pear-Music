import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../models/playlist.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/history_service.dart';
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

  /// Play log backing the History tab. Optional so tests and any host that
  /// does not need history can omit it.
  final HistoryService? history;

  AppController({
    required this.identity,
    required this.library,
    required this.player,
    required this.youtube,
    this.history,
  });

  List<Song> get songs => library.songs;

  Set<String> get favoriteSongIds => identity.favoriteSongIds;
  bool isFavorite(String songId) => identity.isFavorite(songId);

  /// Played songs, most recent first, resolved against the library and the
  /// known online songs. Entries whose song is gone are skipped, so a deleted
  /// song never leaves a dead row behind, and a song played once as a stream
  /// and once as its downloaded copy occupies a single row (the newest
  /// representation wins), matching how favorites treat video copies.
  List<Song> get historySongs {
    final cached = _cachedHistorySongs;
    if (cached != null) return cached;
    final log = history;
    if (log == null || log.isEmpty) return const [];
    final result = <Song>[];
    final seenIds = <String>{};
    final seenVideoIds = <String>{};
    for (final entry in log.entries) {
      if (seenIds.contains(entry.songId)) continue;
      final song = findSongById(entry.songId);
      if (song == null) continue;
      final videoId = _videoIdOf(song, entry.songId);
      if (videoId != null) {
        if (seenVideoIds.contains(videoId)) continue;
        seenVideoIds.add(videoId);
      }
      result.add(song);
      seenIds.add(entry.songId);
    }
    _cachedHistorySongs = result;
    return result;
  }

  Future<void> clearHistory() async {
    await history?.clear();
    notifyListeners();
  }

  /// Drops history entries whose song is no longer reachable, so the stored
  /// list stays short after library removals.
  void _pruneHistory() {
    history?.prune((id) => findSongById(id) != null);
  }

  List<Song>? _cachedFavoriteSongs;
  List<Song>? _cachedHistorySongs;
  List<Song>? _lastSortInput;
  SortOption? _lastSortOption;
  List<Song>? _lastSortResult;

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    _cachedFavoriteSongs = null;
    _cachedHistorySongs = null;
    _lastSortInput = null;
    _lastSortResult = null;
    super.notifyListeners();
  }

  /// YouTube identity of a song, spanning representations: library downloads
  /// carry it in the file name, online entries in the id. Null for plain local
  /// files, which cannot collide with an online copy.
  String? _videoIdOf(Song? song, String songId) {
    if (song != null) {
      final fromFile = LibraryProfile.videoIdOf(song);
      if (fromFile != null) return fromFile;
    }
    if (songId.startsWith('stream_') || songId.startsWith('yt_')) {
      return RecommendationService.extractVideoId(songId) ??
          songId.replaceFirst('stream_', '');
    }
    return null;
  }

  List<Song> get favoriteSongs {
    if (_cachedFavoriteSongs != null) return _cachedFavoriteSongs!;
    final List<Song> result = [];
    final seenIds = <String>{};
    final seenVideoIds = <String>{};
    void add(Song song) {
      if (seenIds.contains(song.id)) return;
      final videoId = _videoIdOf(song, song.id);
      // One entry per video: the library download wins over the online entry,
      // so a favourited song cannot show up twice after downloading it.
      if (videoId != null && seenVideoIds.contains(videoId)) return;
      result.add(song);
      seenIds.add(song.id);
      if (videoId != null) seenVideoIds.add(videoId);
    }

    for (final s in library.songs) {
      if (identity.isFavorite(s.id)) add(s);
    }
    for (final s in identity.favoriteOnlineSongs.values) {
      if (identity.isFavorite(s.id)) add(s);
    }
    for (final id in identity.favoriteSongIds) {
      if (id.startsWith('stream_') || id.startsWith('yt_')) {
        final videoId = RecommendationService.extractVideoId(id) ??
            id.replaceFirst('stream_', '');
        add(Song(
          id: id,
          title: 'Online Stream ($videoId)',
          fileName: 'stream_$videoId.m4a',
          size: 0,
          checksum: id,
          sourceDeviceId: 'stream',
          addedAt: DateTime.now(),
        ));
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
    final wasFavorite = identity.isFavorite(songId);
    await identity.toggleFavorite(songId, song: resolvedSong);
    // A video and its downloaded copy are the same song for the user, so the
    // heart state follows every representation. Without this, downloading a
    // favourited online song left two hearts that could only be toggled
    // separately.
    final videoId = _videoIdOf(resolvedSong, songId);
    if (videoId != null) {
      if (wasFavorite) {
        await _removeVideoFavorites(videoId, exceptId: songId);
      } else {
        await _heartVideoCopies(videoId, exceptId: songId);
      }
    }
    notifyListeners();
  }

  /// Hearts the other representations of the same video (library downloads and
  /// known online entries) so every heart icon shows the same state.
  Future<void> _heartVideoCopies(String videoId,
      {required String exceptId}) async {
    for (final s in library.songs) {
      if (s.id == exceptId || identity.isFavorite(s.id)) continue;
      if (_videoIdOf(s, s.id) != videoId) continue;
      await identity.toggleFavorite(s.id, song: s);
    }
    final streamId = 'stream_$videoId';
    if (streamId != exceptId && !identity.isFavorite(streamId)) {
      final online = identity.findOnlineSong(streamId);
      if (online != null) {
        await identity.toggleFavorite(streamId, song: online);
      }
    }
  }

  /// Clears the other representations of the same video so unfavouriting one
  /// copy cannot leave a stale entry (or a second heart) behind.
  Future<void> _removeVideoFavorites(String videoId,
      {required String exceptId}) async {
    final others = <String>{};
    for (final s in library.songs) {
      if (s.id == exceptId || !identity.isFavorite(s.id)) continue;
      if (_videoIdOf(s, s.id) == videoId) others.add(s.id);
    }
    for (final id in identity.favoriteSongIds) {
      if (id == exceptId) continue;
      if (_videoIdOf(identity.findOnlineSong(id), id) == videoId) {
        others.add(id);
      }
    }
    if (others.isNotEmpty) {
      await identity.removeFavorites(others);
    }
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

    // Playback failures explain themselves through the same snackbar feed as
    // library actions, so the user always learns why a track stopped.
    _subs.add(player.userMessages.listen(_postMessage));

    _removeNotifierListeners.addAll([
      () => library.removeListener(notifyListeners),
      () => player.removeListener(notifyListeners),
      () => identity.removeListener(notifyListeners),
      if (history != null) () => history!.removeListener(notifyListeners),
    ]);
    library.addListener(notifyListeners);
    player.addListener(notifyListeners);
    identity.addListener(notifyListeners);
    history?.addListener(notifyListeners);

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
      // On Android the activity gets destroyed on every back gesture, but the
      // FlutterEngine can keep running behind the media notification:
      // audio_service pins it in a FlutterEngineCache for as long as its
      // foreground service lives, so this isolate survives the activity and
      // reopening the app lands right back in it. Tearing everything down
      // here left that surviving isolate with disposed services and a
      // controller that never notified again, which is why the reopened app
      // looked frozen. Real process death releases everything anyway, and
      // desktop exits go through didRequestAppExit instead.
      if (defaultTargetPlatform != TargetPlatform.android) {
        debugPrint('[app] app detached: executing full cleanup');
        unawaited(disposeAll());
      }
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
      if (LibraryProfile.isProfile(content)) {
        _postMessage(
          'That file is a library profile, not a playlist. Use Import Library Profile from the library header.',
        );
        return;
      }
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

  /// Relaunches the app into a fresh process. Used after bulk imports: the
  /// Dart heap stays grown after heavy work until a restart, so the only way
  /// to fully release that memory is a new process.
  Future<void> restartApp() async {
    try {
      if (kIsWeb) return;
      if (Platform.isWindows) {
        await library.flushSaveIndex();
        final exe = Platform.resolvedExecutable;
        await Process.start(
          exe,
          const [],
          mode: ProcessStartMode.detached,
          workingDirectory: File(exe).parent.path,
        );
        exit(0);
      } else if (Platform.isAndroid) {
        await library.flushSaveIndex();
        await const MethodChannel('com.peerm.peerm_app/memory')
            .invokeMethod('restartApp');
      }
    } catch (e) {
      debugPrint('[controller] restart failed: $e');
    }
  }

  /// Best-effort foreground-service keep-alive for background imports on
  /// Android, so the OS does not freeze the process mid-batch.
  Future<void> _importWake(String method, [String? text]) async {
    try {
      await const MethodChannel('com.peerm.peerm_app/memory').invokeMethod(
        method,
        text == null ? null : {'text': text},
      );
    } catch (_) {}
  }

  /// Writes the portable library profile (link-added songs only) to a file.
  Future<void> exportLibraryProfile() async {
    try {
      final favoriteVideoIds = <String>{};
      final exportedVideoIds = <String>{};
      for (final song in library.songs) {
        final videoId = LibraryProfile.videoIdOf(song);
        if (videoId == null) continue;
        exportedVideoIds.add(videoId);
        if (isFavorite(song.id)) favoriteVideoIds.add(videoId);
      }
      // Online-only favorites transfer as stream references (title + artwork
      // only), never as downloads. Video IDs already present as playlist
      // entries are skipped so the receiving device gets no duplicate.
      final onlineFavorites = <ProfileOnlineFavorite>[];
      for (final id in identity.favoriteSongIds) {
        if (!id.startsWith('stream_')) continue;
        final videoId = RecommendationService.extractVideoId(id);
        if (videoId == null || exportedVideoIds.contains(videoId)) continue;
        final meta = identity.favoriteOnlineSongs[id];
        final artwork = meta?.artwork;
        onlineFavorites.add(ProfileOnlineFavorite(
          videoId: videoId,
          title: meta?.title ?? '',
          artwork: (artwork != null && artwork.startsWith('http'))
              ? artwork
              : null,
        ));
      }
      final content = LibraryProfile.build(
        library.songs,
        favoriteVideoIds: favoriteVideoIds,
        onlineFavorites: onlineFavorites,
      );
      if (content == null) {
        _postMessage(
          'Nothing to export yet: the library has no link-added songs and there are no online favorites.',
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
      final fileContent = await file.readAsString();
      if (!LibraryProfile.isProfile(fileContent)) {
        _postMessage(
          'That file is a playlist, not a library profile. Import playlists from the Playlists tab.',
        );
        return null;
      }
      final entries = LibraryProfile.parse(fileContent);
      final favoriteIds = LibraryProfile.parseFavoriteIds(fileContent);
      final onlineFavorites = LibraryProfile.parseOnlineFavorites(fileContent);
      if (entries.isEmpty && onlineFavorites.isEmpty) {
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
        // Everything downloadable is already here, but hearts and online
        // favorites may still be missing.
        final restored = await _restoreProfileFavorites(favoriteIds) +
            await _restoreOnlineFavorites(onlineFavorites);
        final base = entries.isEmpty
            ? 'Profile applied'
            : 'All $skipped song(s) in that profile are already in the library';
        _postMessage(
          restored > 0 ? '$base. Restored $restored favorite(s).' : '$base.',
        );
        return (added: 0, skipped: skipped, failed: 0, cancelled: false);
      }

      _profileImporting = true;
      _profileImportCancel = DownloadCancellation();
      final cancel = _profileImportCancel!;
      final isAndroid = !kIsWeb && Platform.isAndroid;
      // Coalesce index writes: without this every imported song re-encodes the
      // entire library (all base64 artwork) and raises the heap for good.
      library.deferIndexSaves = true;
      if (isAndroid) {
        // Keep the process foregrounded while the import runs so Android does
        // not freeze the app if it is backgrounded mid-import.
        unawaited(_importWake('startImportWake', 'Preparing…'));
      }
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
          if (isAndroid) {
            unawaited(_importWake(
              'updateImportWake',
              'Fetching ${i + 1} of ${todo.length}: $label',
            ));
          }
          final url = 'https://www.youtube.com/watch?v=${entry.videoId}';
          try {
            final song = await (isAndroid
                ? youtube.scrapeAndAddWithEmbeddedYtDlp(library, url,
                    onStatus: onStatus, onProgress: onBytes, cancel: cancel)
                : youtube.scrapeAndAddWithYtDlp(library, url,
                    onStatus: onStatus, onProgress: onBytes, cancel: cancel));
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
        library.deferIndexSaves = false;
        await library.flushSaveIndex();
        if (isAndroid) {
          await _importWake('stopImportWake');
        }
      }

      // Restore the hearts the profile marked as favorites, and recreate the
      // online-only favorites as stream references. Both also cover songs
      // that were already in the library, so re-importing a profile repairs
      // missing hearts instead of skipping them.
      final favoritesRestored = await _restoreProfileFavorites(favoriteIds) +
          await _restoreOnlineFavorites(onlineFavorites);

      if (added > 0) {
        // The import decoded a cover for every added song; shed those caches
        // so memory settles near a fresh-launch baseline instead of waiting
        // for the next memory-pressure event.
        ArtworkPalette.compactMemory();
        LyricsService.compactMemory();
        PaintingBinding.instance.imageCache.clearLiveImages();
        PaintingBinding.instance.imageCache.clear();
      }

      onProgress?.call(todo.length, todo.length);
      final favoritesNote = favoritesRestored > 0
          ? ', $favoritesRestored favorite${favoritesRestored == 1 ? '' : 's'} restored'
          : '';
      _postMessage(
        cancelled
            ? 'Profile import cancelled: $added added, $skipped already had$favoritesNote.'
            : 'Profile import finished: $added added, $skipped already had, $failed failed$favoritesNote.',
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

  /// Hearts every library song whose YouTube ID appears in [favoriteIds] and
  /// returns how many hearts were newly set. Songs that are already favorited
  /// are left untouched.
  Future<int> _restoreProfileFavorites(Set<String> favoriteIds) async {
    var restored = 0;
    if (favoriteIds.isEmpty) return restored;
    for (final song in library.songs) {
      final videoId = LibraryProfile.videoIdOf(song);
      if (videoId == null || !favoriteIds.contains(videoId)) continue;
      if (isFavorite(song.id)) continue;
      await toggleFavorite(song.id, song: song);
      restored++;
    }
    return restored;
  }

  /// Recreates the profile's online-only favorites as stream references and
  /// hearts any matching song that already exists as a local download.
  /// Nothing is downloaded here; returns how many favorites were newly set.
  Future<int> _restoreOnlineFavorites(
    List<ProfileOnlineFavorite> favorites,
  ) async {
    var restored = 0;
    if (favorites.isEmpty) return restored;
    final libraryByVideoId = <String, Song>{};
    for (final song in library.songs) {
      final videoId = LibraryProfile.videoIdOf(song);
      if (videoId != null) libraryByVideoId[videoId] = song;
    }
    for (final fav in favorites) {
      final existing = libraryByVideoId[fav.videoId];
      if (existing != null) {
        // The song is already downloaded here; heart it instead of adding a
        // second stream reference for the same video.
        if (isFavorite(existing.id)) continue;
        await toggleFavorite(existing.id, song: existing);
        restored++;
        continue;
      }
      final streamId = 'stream_${fav.videoId}';
      if (isFavorite(streamId)) continue;
      final title = fav.title.isEmpty ? fav.videoId : fav.title;
      final song = Song(
        id: streamId,
        title: title,
        fileName: '$title [${fav.videoId}].m4a',
        size: 200 * 16000,
        checksum: streamId,
        sourceDeviceId: 'stream',
        artwork: fav.artwork,
        addedAt: DateTime.now(),
      );
      await identity.registerOnlineSongs([song]);
      await toggleFavorite(streamId, song: song);
      restored++;
    }
    return restored;
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
    _pruneHistory();
    _postMessage('Removed "${song.title}"');
  }

  Future<void> removeSongs(List<Song> songs) async {
    final songIds = songs.map((s) => s.id).toSet();
    player.removeSongsFromQueue(songIds);
    await identity.removeFavorites(songIds);
    await library.removeSongs(songIds);
    _pruneHistory();
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

  Future<void> updateReducedEffects(bool val) async {
    await identity.setReducedEffects(val);
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
