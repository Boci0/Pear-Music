import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/playlist.dart';
import '../models/song.dart';
import 'identity_service.dart';
import 'library_service.dart';
import 'relay_data_channel.dart';

/// Progress of an in-flight transfer (for the UI).
class TransferProgress {
  final String peerId;
  final String songId;
  final String fileName;
  final bool isDownload;
  final int totalBytes;
  int completedBytes;

  TransferProgress({
    required this.peerId,
    required this.songId,
    required this.fileName,
    required this.isDownload,
    required this.totalBytes,
    this.completedBytes = 0,
  });

  double get fraction =>
      totalBytes == 0 ? 0 : (completedBytes / totalBytes).clamp(0.0, 1.0);

  bool get isDone => completedBytes >= totalBytes;

  String get key => '$peerId|$songId|${isDownload ? 'd' : 'u'}';
}

/// Overall batch state for single-card progress display.
class SyncBatchState {
  final int totalSongs;
  final int completedSongs;
  final String activeSongTitle;
  final int activeBytes;
  final int activeTotalBytes;
  final int totalBytes;
  final int completedBytes;
  final bool isDownload;
  final bool isDone;

  const SyncBatchState({
    required this.totalSongs,
    required this.completedSongs,
    required this.activeSongTitle,
    required this.activeBytes,
    required this.activeTotalBytes,
    required this.totalBytes,
    required this.completedBytes,
    required this.isDownload,
    this.isDone = false,
  });

  double get progressFraction {
    if (isDone) return 1.0;
    if (totalSongs <= 0) return 0.0;
    final activeFraction = activeTotalBytes > 0
        ? (activeBytes / activeTotalBytes).clamp(0.0, 1.0)
        : 0.0;
    return ((completedSongs + activeFraction) / totalSongs).clamp(0.0, 1.0);
  }
}

/// Transfers music files over WebRTC data channels.
class SyncService extends ChangeNotifier {
  static const int chunkSize = 64 * 1024;

  final Duration incomingTimeout;
  static const int maxFinalizeRetries = 2;
  static const Duration resyncInterval = Duration(seconds: 45);

  final IdentityService identity;
  final LibraryService library;

  SyncService({
    required this.identity,
    required this.library,
    this.incomingTimeout = const Duration(seconds: 120),
  });

  Timer? _resyncTimer;

  final Map<String, RTCDataChannel> _channels = {};
  final Map<String, _IncomingFile> _incoming = {};
  final Map<String, bool> _sending = {};
  final Map<String, TransferProgress> _transfers = {};

  final Map<String, int> _finalizeRetries = {};
  final Map<String, TransferProgress> _completed = {};
  final Map<String, Timer> _inboundWatchdogs = {};
  Timer? _completedTimer;

  Timer? _notifyTimer;
  bool _notifyQueued = false;

  // ---- Set-based Deduplicated Batch Tracking ----
  final Set<String> _inboundPending = {};
  final Set<String> _inboundCompleted = {};
  final Set<String> _outboundPending = {};
  final Set<String> _outboundCompleted = {};

  Timer? _batchCompletionTimer;
  bool _batchIsDone = false;

  SyncBatchState? get batchState {
    final inTotal = _inboundPending.length + _inboundCompleted.length;
    // Only enter the inbound branch when songs are actively pending. Removing
    // `|| _batchIsDone` prevents this branch from matching during the 2.2s
    // cleanup window when _batchIsDone=true but no inbound work remains —
    // that caused the bar to flip between download and upload states.
    if (inTotal > 0 && _inboundPending.isNotEmpty) {
      final active = _transfers.values.where((t) => t.isDownload).firstOrNull ??
          _completed.values.where((t) => t.isDownload).lastOrNull;
      final totalB = _transfers.values
          .where((t) => t.isDownload)
          .fold<int>(0, (sum, t) => sum + t.totalBytes);
      final compB = _transfers.values
          .where((t) => t.isDownload)
          .fold<int>(0, (sum, t) => sum + t.completedBytes);
      return SyncBatchState(
        totalSongs: inTotal,
        completedSongs: _inboundCompleted.length,
        activeSongTitle: active?.fileName ?? '',
        activeBytes: active?.completedBytes ?? 0,
        activeTotalBytes: active?.totalBytes ?? 0,
        totalBytes: totalB,
        completedBytes: compB,
        isDownload: true,
        isDone: _batchIsDone || _inboundPending.isEmpty,
      );
    }

    final outTotal = _outboundPending.length + _outboundCompleted.length;
    if (outTotal > 0 && _outboundPending.isNotEmpty) {
      final active = _transfers.values.where((t) => !t.isDownload).firstOrNull ??
          _completed.values.where((t) => !t.isDownload).lastOrNull;
      final totalB = _transfers.values
          .where((t) => !t.isDownload)
          .fold<int>(0, (sum, t) => sum + t.totalBytes);
      final compB = _transfers.values
          .where((t) => !t.isDownload)
          .fold<int>(0, (sum, t) => sum + t.completedBytes);
      return SyncBatchState(
        totalSongs: outTotal,
        completedSongs: _outboundCompleted.length,
        activeSongTitle: active?.fileName ?? '',
        activeBytes: active?.completedBytes ?? 0,
        activeTotalBytes: active?.totalBytes ?? 0,
        totalBytes: totalB,
        completedBytes: compB,
        isDownload: false,
        isDone: _batchIsDone || _outboundPending.isEmpty,
      );
    }

    if (transfers.isNotEmpty) {
      final active = transfers.firstWhere((t) => !t.isDone, orElse: () => transfers.last);
      final totalB = transfers.fold<int>(0, (sum, t) => sum + t.totalBytes);
      final compB = transfers.fold<int>(0, (sum, t) => sum + t.completedBytes);
      final doneCount = transfers.where((t) => t.isDone).length;
      return SyncBatchState(
        totalSongs: transfers.length,
        completedSongs: doneCount,
        activeSongTitle: active.fileName,
        activeBytes: active.completedBytes,
        activeTotalBytes: active.totalBytes,
        totalBytes: totalB,
        completedBytes: compB,
        isDownload: active.isDownload,
        isDone: doneCount >= transfers.length,
      );
    }
    return null;
  }

  void _checkBatchCompletion() {
    final inTotal = _inboundPending.length + _inboundCompleted.length;
    final outTotal = _outboundPending.length + _outboundCompleted.length;

    final inboundFinished = inTotal > 0 && _inboundPending.isEmpty;
    final outboundFinished = outTotal > 0 && _outboundPending.isEmpty;

    if (inboundFinished || outboundFinished) {
      _batchIsDone = true;
      _flushNotify();
      _batchCompletionTimer?.cancel();
      _batchCompletionTimer = Timer(const Duration(milliseconds: 2200), () {
        _inboundPending.clear();
        _inboundCompleted.clear();
        _outboundPending.clear();
        _outboundCompleted.clear();
        _batchIsDone = false;
        _flushNotify();
      });
    }
  }

  Future<void> _syncTail = Future<void>.value();
  Future<void> get idle => _syncTail;

  void _track(Future<void> future) {
    _syncTail = _syncTail.then((_) async {
      try {
        await future;
      } catch (e) {
        debugPrint('[sync] protocol handler failed: $e');
      }
    });
  }

  Future<void> Function(String songId, String title)? onRemoteDeleted;
  void Function(String title)? onDownloaded;

  List<TransferProgress> get transfers => [
        ..._transfers.values,
        ..._completed.values,
      ];

  bool hasChannel(String peerId) => _channels.containsKey(peerId);
  int get channelCount => _channels.length;

  void detachChannelAll() {
    for (final peerId in _channels.keys.toList()) {
      detachChannel(peerId);
    }
  }

  // ---------- channel lifecycle ----------

  void attachChannel(String peerId, RTCDataChannel channel) {
    _channels[peerId] = channel;
    channel.onMessage = (msg) => _onMessage(peerId, msg);
    final e2ePub =
        channel is RelayDataChannel ? channel.signaling.e2ePubB64 : null;
    debugPrint('[sync] attachChannel $peerId (e2ePub present: ${e2ePub != null})');
    _send(peerId, {
      'type': 'hello',
      'deviceName': identity.deviceName,
      'e2ePub': e2ePub,
    });
    _send(peerId, {
      'type': 'manifest',
      'songs': library.songs.map((s) => s.toJson()).toList(),
    });
    _send(peerId, _playlistManifestMessage());
    notifyListeners();
    _startResyncTimer();
  }

  void _startResyncTimer() {
    _resyncTimer?.cancel();
    _resyncTimer = Timer.periodic(resyncInterval, (_) => resyncNow());
  }

  Map<String, dynamic> _playlistManifestMessage() => {
        'type': 'playlist_manifest',
        'playlists': library.playlists.map((pl) => pl.toJson()).toList(),
        'deleted': {
          for (final e in library.deletedPlaylistsAt.entries)
            e.key: e.value.toIso8601String(),
        },
      };

  int resyncNow() {
    // Do NOT clear _sending or _sendQueues: those hold in-flight transfers.
    // Clearing _sending allowed a second concurrent sender for the same song
    // to start (_sendFile's guard check no longer sees the in-progress entry),
    // interleaving chunks from two senders and corrupting the file on the
    // receiver. Let active transfers finish naturally; only clear finalize-retry
    // state so a previously failed finalize can be retried by the fresh manifest
    // exchange below.
    _finalizeRetries.clear();
    if (_channels.isEmpty) return 0;
    final count = _channels.length;
    for (final peerId in _channels.keys.toList()) {
      _send(peerId, {
        'type': 'manifest',
        'songs': library.songs.map((s) => s.toJson()).toList(),
      });
      _send(peerId, _playlistManifestMessage());
      _send(peerId, {'type': 'request_manifest'});
    }
    return count;
  }

  void detachChannel(String peerId) {
    _channels.remove(peerId);
    _sendQueues.remove(peerId);
    _inboundWatchdogs.remove(peerId)?.cancel();
    if (_channels.isEmpty) {
      _resyncTimer?.cancel();
      _resyncTimer = null;
    }
    final incomplete =
        _incoming.values.where((inc) => inc.peerId == peerId).toList();
    for (final inc in incomplete) {
      inc.timeoutTimer?.cancel();
      _incoming.remove(inc.song.id);
      _finalizeRetries.remove(inc.song.id);
      try {
        inc.raf.closeSync();
        library.incomingFile(inc.song.id).deleteSync();
      } catch (_) {}
      _removeProgress(peerId, inc.song.id);
    }
    _inboundCompleted.clear();
    _inboundPending.clear();
    _outboundCompleted.clear();
    _outboundPending.clear();
    _sending.removeWhere((k, _) => k.startsWith('$peerId|'));
    notifyListeners();
  }

  // ---------- message handling ----------

  void _onMessage(String peerId, RTCDataChannelMessage msg) {
    if (msg.isBinary) {
      _onBinary(peerId, msg.binary);
    } else {
      _onText(peerId, msg.text);
    }
  }

  void _onText(String peerId, String text) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'hello':
        debugPrint('[sync] <- $peerId: hello (e2ePub: ${msg['e2ePub'] != null})');
        final e2ePub = msg['e2ePub'];
        final ch = _channels[peerId];
        if (e2ePub is String && ch is RelayDataChannel) {
          try {
            unawaited(ch.signaling.setPeerE2E(peerId, base64Decode(e2ePub)));
          } catch (_) {}
        }
        _send(peerId, {
          'type': 'manifest',
          'songs': library.songs.map((s) => s.toJson()).toList(),
        });
        _send(peerId, _playlistManifestMessage());
        break;
      case 'manifest':
        debugPrint('[sync][diag] <- $peerId: manifest (${(msg['songs'] as List?)?.length ?? 0} songs)');
        _onManifest(peerId, msg['songs'] as List? ?? []);
        break;
      case 'request_songs':
        debugPrint('[sync][diag] <- $peerId: request_songs (${(msg['ids'] as List?)?.length ?? 0})');
        _onRequestSongs(peerId, msg['ids'] as List? ?? []);
        break;
      case 'file_meta':
        debugPrint('[sync][diag] <- $peerId: file_meta (${(msg['song'] as Map)['title'] ?? '?'})');
        _startIncoming(peerId, msg['song'] as Map<String, dynamic>);
        break;
      case 'file_done':
        _track(_finalizeIncoming(peerId, msg['id'] as String));
        break;
      case 'file_error':
        _track(_abortIncoming(peerId, msg['id'] as String));
        break;
      case 'song_deleted':
        _track(_onRemoteDeleted(peerId, msg));
        break;
      case 'playlist_manifest':
        _track(_onPlaylistManifest(peerId, msg));
        break;
      case 'playlist_upsert':
        _track(_onPlaylistUpsert(peerId, msg));
        break;
      case 'playlist_delete':
        _track(_onPlaylistDelete(peerId, msg));
        break;
      case 'request_manifest':
        _send(peerId, {
          'type': 'manifest',
          'songs': library.songs.map((s) => s.toJson()).toList(),
        });
        _send(peerId, _playlistManifestMessage());
        break;
    }
  }

  void _onManifest(String peerId, List<dynamic> rawSongs) {
    final missing = <String>[];
    for (final raw in rawSongs) {
      if (raw is! Map) continue;
      final song = Song.fromJson(Map<String, dynamic>.from(raw));
      if (song.sourceDeviceId == identity.deviceId) {
        if (library.findById(song.id) == null) {
          _send(peerId, {
            'type': 'song_deleted',
            'id': song.id,
            'checksum': song.checksum,
            'title': song.title,
          });
        }
        continue;
      }
      final hasMatchingSong = library.songs.any(
        (s) =>
            (s.id == song.id || s.checksum == song.checksum) &&
            library.hasSongFile(s),
      );

      final isAlreadyInFlight = _inboundPending.contains(song.id) ||
          _incoming.containsKey(song.id);

      if (!hasMatchingSong && !isAlreadyInFlight) {
        missing.add(song.id);
      }
    }
    if (missing.isNotEmpty) {
      debugPrint(
          '[sync][diag] requesting ${missing.length} missing songs from $peerId');
      _batchCompletionTimer?.cancel();
      _batchIsDone = false;
      for (final id in missing) {
        if (!_inboundCompleted.contains(id)) {
          _inboundPending.add(id);
        }
      }
      _send(peerId, {'type': 'request_songs', 'ids': missing});
      _inboundWatchdogs[peerId]?.cancel();
      _inboundWatchdogs[peerId] = Timer(const Duration(seconds: 8), () {
        _inboundWatchdogs.remove(peerId);
        final stillPending =
            _inboundPending.where((id) => !_incoming.containsKey(id)).toList();
        if (stillPending.isNotEmpty && _channels.containsKey(peerId)) {
          debugPrint(
              '[sync] still waiting for ${stillPending.length} pending songs from $peerId; retrying request');
          _send(peerId, {'type': 'request_songs', 'ids': stillPending});
        }
      });
      _flushNotify();
    } else {
      debugPrint(
          '[sync][diag] nothing missing from $peerId (${rawSongs.length} advertised)');
    }
  }

  final Map<String, Future<void>> _sendQueues = {};

  void _enqueueSend(String peerId, Song song) {
    final prev = _sendQueues[peerId] ?? Future<void>.value();
    final next = prev.then((_) async {
      if (_channels.containsKey(peerId)) {
        await _sendFile(peerId, song);
      } else {
        // Peer disconnected while waiting in queue: clean up pending state
        _outboundPending.remove(song.id);
        _removeProgress(peerId, song.id);
        _checkBatchCompletion();
      }
    }).catchError((Object e) {
      debugPrint('[sync] send error for ${song.title}: $e');
      _outboundPending.remove(song.id);
      _removeProgress(peerId, song.id);
      _checkBatchCompletion();
    });
    _sendQueues[peerId] = next;
    _track(next);
  }

  void _onRequestSongs(String peerId, List<dynamic> ids) {
    for (final id in ids) {
      final song = library.findById(id as String);
      if (song != null) {
        final sendKey = _sendKey(peerId, song.id);
        if (_sending.containsKey(sendKey)) {
          // Already actively in-flight to this peer; do not duplicate
          continue;
        }
        if (!_outboundCompleted.contains(song.id)) {
          _outboundPending.add(song.id);
        }
        _enqueueSend(peerId, song);
      }
    }
    _batchCompletionTimer?.cancel();
    _batchIsDone = false;
    _flushNotify();
  }

  // ---------- sending ----------

  Future<void> broadcastSong(Song song) async {
    for (final peerId in _channels.keys.toList()) {
      _enqueueSend(peerId, song);
    }
  }

  Future<void> _sendFile(String peerId, Song song) async {
    final sendKey = _sendKey(peerId, song.id);
    if (_sending.containsKey(sendKey)) return;
    final channel = _channels[peerId];
    if (channel == null) return;

    _sending[sendKey] = true;
    _setProgress(
      TransferProgress(
        peerId: peerId,
        songId: song.id,
        fileName: song.title,
        isDownload: false,
        totalBytes: song.size,
      ),
    );

    _send(peerId, {'type': 'file_meta', 'song': song.toJson()});

    try {
      final file = library.songFile(song);
      if (!await file.exists()) throw Exception('local file missing');
      final fileSize = await file.length();
      final total = fileSize == 0 ? 1 : (fileSize / chunkSize).ceil();
      var index = 0;
      var sentBytes = 0;

      final raf = await file.open(mode: FileMode.read);
      try {
        while (sentBytes < fileSize) {
          final toRead = (fileSize - sentBytes) > chunkSize
              ? chunkSize
              : (fileSize - sentBytes);
          final piece = await raf.read(toRead);
          if (piece.isEmpty) break;
          await _sendChunk(channel, song.id, index, total, piece);
          index++;
          sentBytes += piece.length;
          _updateUploadProgress(peerId, song.id, sentBytes);
          if (index % 4 == 0) {
            await Future.delayed(const Duration(milliseconds: 1));
          }
        }
      } finally {
        await raf.close();
      }

      _send(peerId, {'type': 'file_done', 'id': song.id});
      _outboundPending.remove(song.id);
      _outboundCompleted.add(song.id);
      _markComplete(peerId, song.id);
      _checkBatchCompletion();
    } catch (e) {
      debugPrint('[sync] send failed $song: $e');
      _send(peerId, {'type': 'file_error', 'id': song.id, 'message': '$e'});
      _outboundPending.remove(song.id);
      _removeProgress(peerId, song.id);
      _checkBatchCompletion();
    } finally {
      _sending.remove(sendKey);
    }
  }

  String _sendKey(String peerId, String songId) => '$peerId|$songId';

  Future<void> _sendChunk(
    RTCDataChannel channel,
    String songId,
    int index,
    int total,
    List<int> payload,
  ) async {
    final envelope = _buildEnvelope(songId, index, total, payload);
    await channel.send(RTCDataChannelMessage.fromBinary(envelope));

    // Yield every 2 chunks so the event loop stays responsive
    if (index % 2 == 0) {
      await Future<void>.delayed(Duration.zero);
    }

    final buffered = channel.bufferedAmount ?? 0;
    if (buffered > 512 * 1024) {
      final low = Completer<void>();
      channel.bufferedAmountLowThreshold = 64 * 1024;
      channel.onBufferedAmountLow = (_) {
        if (!low.isCompleted) low.complete();
      };
      try {
        await low.future.timeout(const Duration(milliseconds: 1500));
      } catch (_) {}
    }
  }

  // ---------- receiving ----------

  void _startIncoming(String peerId, Map<String, dynamic> songJson) {
    _inboundWatchdogs.remove(peerId)?.cancel();
    final song = Song.fromJson(songJson);
    if (library.findById(song.id) != null ||
        library.hasChecksum(song.checksum)) {
      debugPrint('[sync][diag] file_meta for ${song.title} already have; skipping');
      _send(peerId, {'type': 'file_done', 'id': song.id});
      return;
    }

    final existing = _incoming.remove(song.id);
    if (existing != null) {
      existing.timeoutTimer?.cancel();
      try {
        existing.raf.closeSync();
      } catch (_) {}
    }

    final file = library.incomingFile(song.id);
    file.parent.createSync(recursive: true);
    if (file.existsSync()) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
    final raf = file.openSync(mode: FileMode.append);
    final inc = _IncomingFile(
      peerId: peerId,
      song: song,
      file: file,
      raf: raf,
    );

    inc.timeoutTimer = Timer(const Duration(seconds: 8), () {
      if (inc.bytesReceived == 0) {
        debugPrint('[sync] incoming ${song.id} stalled at 0% (8s watchdog); retrying request');
        _send(peerId, {'type': 'request_songs', 'ids': [song.id]});
        // Restart a second watchdog for final abort if still stalled
        inc.timeoutTimer = Timer(incomingTimeout, () {
          inc.timeoutTimer = null;
          debugPrint('[sync] incoming ${song.id} timed out; aborting');
          _track(_abortIncoming(peerId, song.id));
        });
      } else {
        inc.timeoutTimer = Timer(incomingTimeout, () {
          inc.timeoutTimer = null;
          debugPrint('[sync] incoming ${song.id} timed out; aborting');
          _track(_abortIncoming(peerId, song.id));
        });
      }
    });
    _incoming[song.id] = inc;
    _setProgress(TransferProgress(
      peerId: peerId,
      songId: song.id,
      fileName: song.title,
      isDownload: true,
      totalBytes: song.size,
    ));
  }

  void _onBinary(String peerId, Uint8List bytes) {
    if (bytes.isEmpty || bytes[0] != 0x50) {
      debugPrint('[sync][diag] <- $peerId: binary frame NOT an envelope (len=${bytes.length})');
      return;
    }
    var off = 1;
    if (bytes.length < 3) return;
    final idLen = (bytes[off] << 8) | bytes[off + 1];
    off += 2;
    if (bytes.length < off + idLen + 8) return;
    final songId = utf8.decode(bytes.sublist(off, off + idLen));
    off += idLen;
    final index = _readUint32(bytes, off);
    off += 4;
    final total = _readUint32(bytes, off);
    off += 4;
    final payload = bytes.sublist(off);

    final inc = _incoming[songId];
    if (inc == null) {
      debugPrint('[sync][diag] <- $peerId: chunk for UNKNOWN song $songId idx=$index/$total dropped');
      return;
    }
    if (index == 0 || index == total - 1) {
      debugPrint('[sync][diag] <- $peerId: chunk $songId idx=$index/$total (${payload.length} bytes)');
    }

    try {
      inc.raf.writeFromSync(payload);
      inc.bytesReceived += payload.length;
    } catch (e) {
      debugPrint('[sync] error writing chunk for $songId: $e');
    }

    inc.timeoutTimer?.cancel();
    // Reset watchdog: if no new chunk arrives within 15 seconds, abort and retry
    inc.timeoutTimer = Timer(const Duration(seconds: 15), () {
      inc.timeoutTimer = null;
      debugPrint('[sync] incoming $songId transfer stalled mid-stream (15s inactivity); aborting and retrying');
      _track(_abortIncoming(peerId, songId));
      _send(peerId, {'type': 'request_songs', 'ids': [songId]});
    });

    final progress = _transfers[TransferProgress(
      peerId: peerId,
      songId: songId,
      fileName: '',
      isDownload: true,
      totalBytes: 0,
    ).key];
    if (progress != null) {
      progress.completedBytes = inc.bytesReceived;
    }
    if (index == total - 1) {
      inc.completeChunks = true;
    }
    _throttledNotify();
  }

  void _throttledNotify() {
    if (_notifyQueued) return;
    _notifyQueued = true;
    _notifyTimer ??= Timer(const Duration(milliseconds: 50), () {
      _notifyQueued = false;
      _notifyTimer = null;
      notifyListeners();
    });
  }

  void _flushNotify() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _notifyQueued = false;
    notifyListeners();
  }

  Future<void> _finalizeIncoming(String peerId, String songId) async {
    final inc = _incoming.remove(songId);
    if (inc == null) return;
    inc.timeoutTimer?.cancel();
    inc.timeoutTimer = null;
    try {
      try {
        inc.raf.closeSync();
      } catch (_) {}
      final length = await inc.file.length();
      if (length != inc.song.size) {
        throw Exception('size mismatch: got $length, expected ${inc.song.size}');
      }
      final actualChecksum = await LibraryService.checksum(inc.file);
      if (actualChecksum != inc.song.checksum) {
        throw Exception(
            'checksum mismatch: got $actualChecksum, expected ${inc.song.checksum}');
      }
      await library.addReceivedSong(
        id: songId,
        title: inc.song.title,
        fileName: inc.song.fileName,
        size: inc.song.size,
        checksum: actualChecksum,
        sourceDeviceId: peerId,
        artwork: inc.song.artwork,
      );
      _inboundPending.remove(songId);
      _inboundCompleted.add(songId);
      _finalizeRetries.remove(songId);
      _markComplete(peerId, songId);
      onDownloaded?.call(inc.song.title);
      _checkBatchCompletion();
    } catch (e) {
      debugPrint('[sync] finalize failed $songId: $e');
      try {
        inc.raf.closeSync();
      } catch (_) {}
      try {
        if (inc.file.existsSync()) {
          inc.file.deleteSync();
        }
      } catch (_) {}
      _removeProgress(peerId, songId);
      final retries = (_finalizeRetries[songId] ?? 0) + 1;
      if (retries <= maxFinalizeRetries) {
        _finalizeRetries[songId] = retries;
        debugPrint(
            '[sync] re-requesting $songId from $peerId (attempt $retries/$maxFinalizeRetries)');
        _send(peerId, {'type': 'request_songs', 'ids': [songId]});
      } else {
        _finalizeRetries.remove(songId);
        _inboundPending.remove(songId);
        _checkBatchCompletion();
        debugPrint(
            '[sync] giving up on $songId after $maxFinalizeRetries failed attempts');
      }
    }
  }

  Future<void> _abortIncoming(String peerId, String songId) async {
    final inc = _incoming.remove(songId);
    if (inc == null) return;
    inc.timeoutTimer?.cancel();
    inc.timeoutTimer = null;
    _finalizeRetries.remove(songId);
    _inboundPending.remove(songId);
    try {
      inc.raf.closeSync();
    } catch (_) {}
    try {
      if (inc.file.existsSync()) {
        inc.file.deleteSync();
      }
    } catch (_) {}
    _removeProgress(peerId, songId);
    _checkBatchCompletion();
  }

  // ---------- helpers ----------

  void _send(String peerId, Map<String, dynamic> msg) {
    final channel = _channels[peerId];
    if (channel == null) return;
    try {
      channel.send(RTCDataChannelMessage(jsonEncode(msg))).catchError((Object e) {
        debugPrint('[sync] send failed: $e');
      });
    } catch (_) {}
  }

  Uint8List _buildEnvelope(
      String songId, int index, int total, List<int> payload) {
    final idBytes = utf8.encode(songId);
    final idLen = idBytes.length;
    final totalLen = 1 + 2 + idLen + 4 + 4 + payload.length;
    final out = Uint8List(totalLen);
    var off = 0;
    out[off++] = 0x50;
    out[off++] = (idLen >> 8) & 0xff;
    out[off++] = idLen & 0xff;
    out.setRange(off, off + idLen, idBytes);
    off += idLen;
    _writeUint32(out, off, index);
    off += 4;
    _writeUint32(out, off, total);
    off += 4;
    out.setRange(off, off + payload.length, payload);
    return out;
  }

  int _readUint32(Uint8List bytes, int offset) {
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  void _writeUint32(Uint8List bytes, int offset, int value) {
    bytes[offset] = (value >> 24) & 0xff;
    bytes[offset + 1] = (value >> 16) & 0xff;
    bytes[offset + 2] = (value >> 8) & 0xff;
    bytes[offset + 3] = value & 0xff;
  }

  void _setProgress(TransferProgress p) {
    _transfers[p.key] = p;
    _flushNotify();
  }

  void _removeProgress(String peerId, String songId) {
    _transfers.removeWhere((k, v) => v.peerId == peerId && v.songId == songId);
    _flushNotify();
  }

  void _markComplete(String peerId, String songId) {
    TransferProgress? found;
    for (final t in _transfers.values) {
      if (t.peerId == peerId && t.songId == songId) {
        found = t;
        break;
      }
    }
    if (found == null) return;
    _transfers.removeWhere((k, v) => v.peerId == peerId && v.songId == songId);
    found.completedBytes = found.totalBytes;
    _completed[found.key] = found;
    _flushNotify();
    // Use ??= so the cleanup timer is started only once per batch, not reset
    // on every completed song. Resetting caused the 1600ms window to keep
    // extending, then clear all completed entries at once — making batchState
    // briefly return null and the progress card flicker off and back on.
    _completedTimer ??= Timer(const Duration(milliseconds: 1600), () {
      _completed.clear();
      _completedTimer = null;
      _flushNotify();
    });
  }

  void _updateUploadProgress(String peerId, String songId, int bytes) {
    final p = _transfers[TransferProgress(
      peerId: peerId,
      songId: songId,
      fileName: '',
      isDownload: false,
      totalBytes: 0,
    ).key];
    if (p == null) return;
    p.completedBytes = bytes;
    _throttledNotify();
  }

  void broadcastSongDeleted(Song song) {
    for (final peerId in _channels.keys.toList()) {
      _send(peerId, {
        'type': 'song_deleted',
        'id': song.id,
        'checksum': song.checksum,
        'title': song.title,
      });
    }
  }

  Future<void> _onRemoteDeleted(
    String peerId,
    Map<String, dynamic> msg,
  ) async {
    final id = msg['id'] as String?;
    if (id == null) return;
    final song = library.findById(id);
    if (song == null || song.sourceDeviceId == null) return;
    await library.removeSong(id);
    await onRemoteDeleted?.call(id, song.title);
  }

  // ---------- playlist sync ----------

  void broadcastPlaylistUpsert(Playlist playlist) {
    for (final peerId in _channels.keys.toList()) {
      _send(peerId, {'type': 'playlist_upsert', 'playlist': playlist.toJson()});
    }
  }

  void broadcastPlaylistDelete(String id, DateTime at) {
    for (final peerId in _channels.keys.toList()) {
      _send(peerId, {
        'type': 'playlist_delete',
        'id': id,
        'at': at.toIso8601String(),
      });
    }
  }

  Future<void> _onPlaylistManifest(
    String peerId,
    Map<String, dynamic> msg,
  ) async {
    final playlists = <Playlist>[];
    for (final item in msg['playlists'] as List? ?? []) {
      if (item is Map) {
        playlists.add(Playlist.fromJson(Map<String, dynamic>.from(item)));
      }
    }
    final deleted = <String, DateTime>{};
    final rawDeleted = msg['deleted'];
    if (rawDeleted is Map) {
      rawDeleted.forEach((key, value) {
        final at = DateTime.tryParse(value.toString());
        if (at != null) deleted[key.toString()] = at;
      });
    }
    final echo = await library.mergeRemotePlaylists(playlists, deleted);
    for (final pl in echo) {
      _send(peerId, {'type': 'playlist_upsert', 'playlist': pl.toJson()});
    }
  }

  Future<void> _onPlaylistUpsert(
    String peerId,
    Map<String, dynamic> msg,
  ) async {
    final raw = msg['playlist'];
    if (raw is! Map) return;
    final pl = Playlist.fromJson(Map<String, dynamic>.from(raw));
    final echo = await library.mergeRemotePlaylists([pl], const {});
    for (final local in echo) {
      _send(peerId, {'type': 'playlist_upsert', 'playlist': local.toJson()});
    }
  }

  Future<void> _onPlaylistDelete(
    String peerId,
    Map<String, dynamic> msg,
  ) async {
    final id = msg['id'] as String?;
    if (id == null) return;
    final at =
        DateTime.tryParse(msg['at'] as String? ?? '') ?? DateTime.now();
    await library.mergeRemotePlaylists(const [], {id: at});
  }

  @override
  void dispose() {
    _resyncTimer?.cancel();
    _resyncTimer = null;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _completedTimer?.cancel();
    _completedTimer = null;
    _batchCompletionTimer?.cancel();
    _batchCompletionTimer = null;
    for (final inc in _incoming.values) {
      inc.timeoutTimer?.cancel();
      try {
        inc.raf.closeSync();
      } catch (_) {}
    }
    _incoming.clear();
    super.dispose();
  }
}

class _IncomingFile {
  final String peerId;
  final Song song;
  final File file;
  final RandomAccessFile raf;
  int bytesReceived = 0;
  bool completeChunks = false;
  Timer? timeoutTimer;

  _IncomingFile({
    required this.peerId,
    required this.song,
    required this.file,
    required this.raf,
  });
}
