part of '../player_service.dart';

mixin _PlayerQueueEdit on ChangeNotifier {
  // What the queue edits need from the player they are mixed into.
  abstract Song? currentSong;
  abstract List<Song> _queue;
  abstract int _queueIndex;
  Set<String> get _lockedSongIds;
  Set<String> get _shufflePlayedSongIds;
  // ignore: unused_element_parameter
  void _preloadUpcomingStreams({Duration delay = const Duration(seconds: 2)});
  void _syncQueueIndexWithCurrentSong();
  void _updateActiveQueueCacheProtection();
  Future<void> stop();
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    String? sourceId,
    String? sourceTitle,
    int? requestToken,
    int? initialIndex,
    bool userInitiated = true,
  });

  /// Inserts [song] immediately after the currently playing track.
  /// If the queue is empty or playback has stopped, starts playback of [song].
  void playNext(Song song) {
    if (_queue.isEmpty || currentSong == null) {
      unawaited(playSong(song, queue: [song]));
      return;
    }
    _shufflePlayedSongIds.remove(song.id);
    _lockedSongIds.add(song.id);

    final mutableQueue = List<Song>.from(_queue);
    mutableQueue.removeWhere((s) => s.id == song.id);

    // Compute insertion position directly against mutableQueue so any prior
    // index shift cannot cause an off-by-one or N+2 displacement.
    final currentIdx = mutableQueue.indexWhere((s) => s.id == currentSong!.id);
    final insertIndex = (currentIdx >= 0) ? currentIdx + 1 : 0;

    mutableQueue.insert(insertIndex, song);
    _queue = mutableQueue;
    _queueIndex = currentIdx >= 0 ? currentIdx : _queue.indexWhere((s) => s.id == currentSong!.id);
    _updateActiveQueueCacheProtection();
    _preloadUpcomingStreams();
    notifyListeners();
  }

  /// Appends [song] to the end of the active queue.
  /// If the queue is empty or playback has stopped, starts playback of [song].
  void addToQueue(Song song) {
    if (_queue.isEmpty || currentSong == null) {
      unawaited(playSong(song, queue: [song]));
      return;
    }
    _shufflePlayedSongIds.remove(song.id);
    _lockedSongIds.add(song.id);
    _queue = [..._queue, song];
    _syncQueueIndexWithCurrentSong();
    _updateActiveQueueCacheProtection();
    _preloadUpcomingStreams();
    notifyListeners();
  }

  /// Batch inserts multiple [songs] into the active queue.
  void addSongsToQueue(List<Song> songs, {bool playNext = false}) {
    if (songs.isEmpty) return;
    if (_queue.isEmpty || currentSong == null) {
      unawaited(playSong(songs.first, queue: songs));
      return;
    }
    for (final s in songs) {
      _shufflePlayedSongIds.remove(s.id);
      if (playNext) {
        _lockedSongIds.add(s.id);
      }
    }
    final mutableQueue = List<Song>.from(_queue);
    if (playNext) {
      final currentIdx = mutableQueue.indexWhere((s) => s.id == currentSong!.id);
      final insertIndex = (currentIdx >= 0) ? currentIdx + 1 : mutableQueue.length;
      mutableQueue.insertAll(insertIndex, songs);
    } else {
      mutableQueue.addAll(songs);
    }
    _queue = mutableQueue;
    _syncQueueIndexWithCurrentSong();
    _updateActiveQueueCacheProtection();
    _preloadUpcomingStreams();
    notifyListeners();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _queue.length ||
        newIndex < 0 ||
        newIndex > _queue.length) {
      return;
    }
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final mutableQueue = List<Song>.from(_queue);
    final item = mutableQueue.removeAt(oldIndex);
    mutableQueue.insert(newIndex, item);
    _queue = mutableQueue;
    _syncQueueIndexWithCurrentSong();
    _updateActiveQueueCacheProtection();
    _preloadUpcomingStreams();
    notifyListeners();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) {
      return;
    }
    if (_queue.length <= 1) {
      unawaited(stop());
      return;
    }
    _syncQueueIndexWithCurrentSong();
    final isRemovingCurrent = index == _queueIndex;
    final removedSong = _queue[index];
    final mutableQueue = List<Song>.from(_queue);
    mutableQueue.removeAt(index);
    _queue = mutableQueue;
    _syncQueueIndexWithCurrentSong();
    _shufflePlayedSongIds.remove(removedSong.id);
    _lockedSongIds.remove(removedSong.id);
    _updateActiveQueueCacheProtection();

    if (isRemovingCurrent) {
      final nextIdx = index < _queue.length ? index : 0;
      _queueIndex = nextIdx;
      final nextSong = _queue[_queueIndex];
      currentSong = nextSong;
      notifyListeners();
      unawaited(playSong(nextSong, queue: _queue, initialIndex: nextIdx));
    } else {
      _syncQueueIndexWithCurrentSong();
      _preloadUpcomingStreams();
      notifyListeners();
    }
  }

  void removeSongsFromQueue(Set<String> songIds) {
    if (songIds.isEmpty || _queue.isEmpty) return;
    final remaining = _queue.where((s) => !songIds.contains(s.id)).toList();
    if (remaining.isEmpty) {
      unawaited(stop());
      return;
    }
    for (final id in songIds) {
      _shufflePlayedSongIds.remove(id);
      _lockedSongIds.remove(id);
    }
    final currentAffected = currentSong != null && songIds.contains(currentSong!.id);
    _syncQueueIndexWithCurrentSong();
    // The first surviving song after the current one (removed songs before
    // it shift the indexes, so the old index cannot be reused as is).
    Song? following;
    for (var i = _queueIndex + 1; i < _queue.length; i++) {
      if (!songIds.contains(_queue[i].id)) {
        following = _queue[i];
        break;
      }
    }
    _queue = remaining;
    if (currentAffected) {
      final nextIdx = following == null
          ? 0
          : _queue.indexWhere((s) => identical(s, following));
      _queueIndex = nextIdx < 0 ? 0 : nextIdx;
      final nextSong = _queue[_queueIndex];
      currentSong = nextSong;
      _updateActiveQueueCacheProtection();
      notifyListeners();
      unawaited(playSong(nextSong, queue: _queue, initialIndex: _queueIndex));
    } else {
      if (currentSong != null) {
        _queueIndex = _queue.indexWhere((s) => s.id == currentSong!.id);
      }
      _updateActiveQueueCacheProtection();
      _preloadUpcomingStreams();
      notifyListeners();
    }
  }
}
