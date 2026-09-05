import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/playlist.dart';
import '../models/song.dart';
import '../services/artwork_palette.dart';
import '../services/identity_service.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/signaling_server.dart';
import '../services/signaling_service.dart';
import '../services/stream_cache_manager.dart';
import '../services/sync_service.dart';
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
  final SignalingService? signaling;
  final SyncService? sync;
  final SignalingServer? server;

  AppController({
    required this.identity,
    required this.library,
    required this.player,
    required this.youtube,
    this.signaling,
    this.sync,
    this.server,
  });

  bool get isHostingServer => false;
  String? get serverLanIp => null;
  String get connectionStatus => 'offline';
  String? get pendingPairingCode => null;

  List<Song> get songs => library.songs;

  Set<String> get favoriteSongIds => identity.favoriteSongIds;
  bool isFavorite(String songId) => identity.isFavorite(songId);
  Future<void> toggleFavorite(String songId) async {
    await identity.toggleFavorite(songId);
    notifyListeners();
  }

  SortOption get sortOption => identity.sortOption;
  Future<void> setSortOption(SortOption option) async {
    await identity.setSortOption(option);
    if (player.hasLoaded &&
        (player.queueSourceId == 'library' ||
            player.queueSourceId == 'favorites' ||
            player.queueSourceId == null)) {
      final sorted = getSortedSongs(player.queue);
      player.updateQueue(sorted);
    }
    notifyListeners();
  }

  List<Song> getSortedSongs(List<Song> songList) {
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
    return list;
  }

  bool _closing = false;

  final _messages = StreamController<String>.broadcast();
  Stream<String> get messages => _messages.stream;

  final List<StreamSubscription> _subs = [];
  final List<VoidCallback> _removeNotifierListeners = [];

  // ---------- lifecycle ----------

  Future<void> init() async {
    await library.init();
    await player.init();

    _removeNotifierListeners.addAll([
      () => library.removeListener(notifyListeners),
      () => player.removeListener(notifyListeners),
    ]);
    library.addListener(notifyListeners);
    player.addListener(notifyListeners);

    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}

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
      debugPrint('[app] app backgrounded: flushing pending saves');
      library.flushSaveIndex();
      ArtworkPalette.compactMemory();
      PaintingBinding.instance.imageCache.clearLiveImages();
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
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final remove in _removeNotifierListeners) {
      remove();
    }
    _removeNotifierListeners.clear();
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

  Future<bool> addSongToPlaylist(String playlistId, String songId) async {
    return await library.addSongToPlaylist(playlistId, songId);
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    await library.removeSongFromPlaylist(playlistId, songId);
  }

  Future<void> reorderPlaylist(String playlistId, List<String> songIds) async {
    await library.setPlaylistSongIds(playlistId, songIds);
  }

  Future<String?> addFromLink(
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
        if (library.findById(id) != null) library.findById(id)!,
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
    if (player.currentSong?.id == song.id) {
      await player.stop();
    }
    await library.removeSong(song.id);
    _postMessage('Removed "${song.title}"');
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
    final saved = await StreamCacheManager.saveToLibrary(song, library);
    if (saved != null) {
      _postMessage('Added "${saved.title}" to library');
      notifyListeners();
    } else {
      _postMessage('Failed to download "${song.title}"');
    }
  }
  Future<void> togglePlayback() => player.toggle();
  Future<void> nextTrack() => player.next();
  Future<void> previousTrack() => player.previous();
  Future<void> toggleLoop() => player.toggleLoop();
  void toggleShuffle() => player.toggleShuffle();
  void reorderQueue(int oldIndex, int newIndex) =>
      player.reorderQueue(oldIndex, newIndex);
  void removeFromQueue(int index) => player.removeFromQueue(index);
  Future<void> seek(Duration d) => player.seek(d);
  Future<void> setVolume(double v) => player.setVolume(v);

  void _postMessage(String text) {
    if (!_messages.isClosed) _messages.add(text);
  }
}
