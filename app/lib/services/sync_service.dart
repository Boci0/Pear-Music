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
    if (totalBytes > 0) {
      final current = (completedBytes + activeBytes).clamp(0, totalBytes);
      return (current / totalBytes).clamp(0.0, 1.0);
    }
    if (totalSongs <= 0) return 0.0;
    final activeFraction = activeTotalBytes > 0
        ? (activeBytes / activeTotalBytes).clamp(0.0, 1.0)
        : 0.0;
    return ((completedSongs + activeFraction) / totalSongs).clamp(0.0, 1.0);
  }
}

class _SyncBatch {
  final int totalSongs;
  int completedSongs;
  final int totalBytes;
  int completedBytes;
  String activeSongTitle;
  int activeBytes;
  int activeTotalBytes;
  final bool isDownload;
  bool isDone;
  Timer? dismissTimer;

  _SyncBatch({
    required this.totalSongs,
    this.completedSongs = 0,
    required this.totalBytes,
    this.completedBytes = 0,
    this.activeSongTitle = '',
    this.activeBytes = 0,
    this.activeTotalBytes = 0,
    required this.isDownload,
    this.isDone = false,
  });

  SyncBatchState toState() => SyncBatchState(
        totalSongs: totalSongs,
        completedSongs: completedSongs,
        activeSongTitle: activeSongTitle,
        activeBytes: activeBytes,
        activeTotalBytes: activeTotalBytes,
        totalBytes: totalBytes,
        completedBytes: completedBytes,
        isDownload: isDownload,
        isDone: isDone,
      );
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
  final Map<String, TransferProgress> _completed = {};
  Timer? _completedTimer;

  _SyncBatch? _inboundBatch;
  _SyncBatch? _outboundBatch;

  Timer? _notifyTimer;
  bool _notifyQueued = false;

  SyncBatchState? get batchState {
    if (_inboundBatch != null) {
      return _inboundBatch!.toState();
    }
    if (_outboundBatch != null) {
      return _outboundBatch!.toState();
    }
    return null;
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
    _sendHelloAndManifest(peerId, channel);
    notifyListeners();
    _startResyncTimer();
  }

  Future<void> _sendHelloAndManifest(
      String peerId, RTCDataChannel channel) async {
    if (channel is RelayDataChannel) {
      await channel.signaling.ensureE2E();
    }
    final e2ePub =
        channel is RelayDataChannel ? channel.signaling.e2ePubB64 : null;
    debugPrint(
        '[sync] attachChannel $peerId (e2ePub present: ${e2ePub != null})');
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
    if (_channels.isEmpty) return 0;
    final count = _channels.length;
    for (final peerId in _channels.keys.toList()) {
      final ch = _channels[peerId];
      final e2ePub =
          ch is RelayDataChannel ? ch.signaling.e2ePubB64 : null;
      _send(peerId, {
        'type': 'hello',
        'deviceName': identity.deviceName,
        'e2ePub': e2ePub,
        'ack': true,
      });
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
    final incomplete =
        _incoming.values.where((inc) => inc.peerId == peerId).toList();
    for (final inc in incomplete) {
      inc.timeoutTimer?.cancel();
      _incoming.remove(inc.song.id);
      try {
        inc.raf.closeSync();
        final partFile = library.incomingFile(inc.song.id);
        if (partFile.existsSync()) partFile.deleteSync();
      } catch (_) {}
      _removeProgress(peerId, inc.song.id);
    }
    _transfers.removeWhere((k, t) => t.peerId == peerId);
    _completed.removeWhere((k, t) => t.peerId == peerId);
    _sending.removeWhere((k, _) => k.startsWith('$peerId|'));

    if (_channels.isEmpty) {
      _resyncTimer?.cancel();
      _resyncTimer = null;
      _inboundBatch?.dismissTimer?.cancel();
      _inboundBatch = null;
      _outboundBatch?.dismissTimer?.cancel();
      _outboundBatch = null;
    }
    _flushNotify();
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
        _track(_onHello(peerId, msg));
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

  Future<void> _onHello(String peerId, Map<String, dynamic> msg) async {
    debugPrint('[sync] <- $peerId: hello (e2ePub: ${msg['e2ePub'] != null})');
    final e2ePub = msg['e2ePub'];
    final ch = _channels[peerId];
    if (ch is RelayDataChannel) {
      await ch.signaling.ensureE2E();
      if (e2ePub is String) {
        try {
          await ch.signaling.setPeerE2E(peerId, base64Decode(e2ePub));
        } catch (e) {
          debugPrint('[sync] error deriving E2E key for $peerId: $e');
        }
      }
      if (msg['ack'] != true) {
        _send(peerId, {
          'type': 'hello',
          'deviceName': identity.deviceName,
          'e2ePub': ch.signaling.e2ePubB64,
          'ack': true,
        });
      }
    }
    _send(peerId, {
      'type': 'manifest',
      'songs': library.songs.map((s) => s.toJson()).toList(),
    });
    _send(peerId, _playlistManifestMessage());
  }

  void _onManifest(String peerId, List<dynamic> rawSongs) {
    final missingSongs = <Song>[];
    for (final raw in rawSongs) {
      if (raw is! Map) continue;
      final song = Song.fromJson(Map<String, dynamic>.from(raw));
      if (song.sourceDeviceId == identity.deviceId) {
        if (library.findById(song.id) == null) {
          // Source device deleted the song while offline — tell peer to drop the copy
          _send(peerId, {
            'type': 'song_deleted',
            'id': song.id,
            'checksum': song.checksum,
            'title': song.title,
          });
          continue;
        }
      }
      final hasMatchingSong = library.songs.any(
        (s) =>
            (s.id == song.id || s.checksum == song.checksum) &&
            library.hasSongFile(s),
      );

      final isActivelyDownloading = _incoming.containsKey(song.id);

      if (!hasMatchingSong && !isActivelyDownloading) {
        missingSongs.add(song);
      }
    }
    if (missingSongs.isNotEmpty) {
      debugPrint(
          '[sync][diag] requesting ${missingSongs.length} missing songs from $peerId');
      _inboundBatch?.dismissTimer?.cancel();
      final totalBytes = missingSongs.fold<int>(0, (sum, s) => sum + s.size);
      _inboundBatch = _SyncBatch(
        totalSongs: missingSongs.length,
        totalBytes: totalBytes,
        isDownload: true,
      );
      _send(peerId, {
        'type': 'request_songs',
        'ids': missingSongs.map((s) => s.id).toList(),
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
        _removeProgress(peerId, song.id);
      }
    }).catchError((Object e) {
      debugPrint('[sync] send error for ${song.title}: $e');
      _removeProgress(peerId, song.id);
    });
    _sendQueues[peerId] = next;
    _track(next);
  }

  void _onRequestSongs(String peerId, List<dynamic> ids) {
    final requestedSongs = <Song>[];
    for (final id in ids) {
      final song = library.findById(id as String);
      if (song != null) {
        requestedSongs.add(song);
      }
    }
    if (requestedSongs.isNotEmpty) {
      _outboundBatch?.dismissTimer?.cancel();
      final totalBytes = requestedSongs.fold<int>(0, (sum, s) => sum + s.size);
      _outboundBatch = _SyncBatch(
        totalSongs: requestedSongs.length,
        totalBytes: totalBytes,
        isDownload: false,
      );
      for (final song in requestedSongs) {
        final sendKey = _sendKey(peerId, song.id);
        if (_sending.containsKey(sendKey)) {
          // Already actively in-flight to this peer; do not duplicate
          continue;
        }
        _enqueueSend(peerId, song);
      }
      _flushNotify();
    }
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
    if (_outboundBatch != null && !_outboundBatch!.isDownload) {
      _outboundBatch!.activeSongTitle = song.title;
      _outboundBatch!.activeTotalBytes = song.size;
      _outboundBatch!.activeBytes = 0;
    }
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
      if (fileSize != song.size && song.size > 0) {
        throw Exception('local file size mismatch ($fileSize vs ${song.size})');
      }
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
          if (_outboundBatch != null && !_outboundBatch!.isDownload) {
            _outboundBatch!.activeBytes = sentBytes;
          }
          _updateUploadProgress(peerId, song.id, sentBytes);
          if (index % 4 == 0) {
            await Future.delayed(const Duration(milliseconds: 1));
          }
        }
      } finally {
        await raf.close();
      }

      _send(peerId, {'type': 'file_done', 'id': song.id});
      _markComplete(peerId, song.id);
      if (_outboundBatch != null && !_outboundBatch!.isDownload) {
        _outboundBatch!.completedSongs++;
        _outboundBatch!.completedBytes += song.size;
        _outboundBatch!.activeSongTitle = '';
        _outboundBatch!.activeBytes = 0;
        _outboundBatch!.activeTotalBytes = 0;
        if (_outboundBatch!.completedSongs >= _outboundBatch!.totalSongs) {
          _outboundBatch!.isDone = true;
          _outboundBatch!.dismissTimer?.cancel();
          _outboundBatch!.dismissTimer =
              Timer(const Duration(milliseconds: 2500), () {
            _outboundBatch = null;
            _flushNotify();
          });
        }
      }
      _flushNotify();
    } catch (e) {
      debugPrint('[sync] send failed $song: $e');
      _send(peerId, {'type': 'file_error', 'id': song.id, 'message': '$e'});
      _removeProgress(peerId, song.id);
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
    final song = Song.fromJson(songJson);
    final hasMatchingFile = library.songs.any(
      (s) =>
          (s.id == song.id || s.checksum == song.checksum) &&
          library.hasSongFile(s),
    );
    if (hasMatchingFile) {
      debugPrint('[sync][diag] file_meta for ${song.title} already have; skipping');
      _send(peerId, {'type': 'file_done', 'id': song.id});
      return;
    }

    final existing = _incoming[song.id];
    if (existing != null && existing.peerId == peerId && existing.bytesReceived > 0) {
      debugPrint(
          '[sync] incoming ${song.id} already active from $peerId (${existing.bytesReceived} bytes); ignoring duplicate file_meta');
      return;
    }
    _incoming.remove(song.id);
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
    final raf = file.openSync(mode: FileMode.write);
    final inc = _IncomingFile(
      peerId: peerId,
      song: song,
      file: file,
      raf: raf,
    );

    final watchdogTimeout = incomingTimeout < const Duration(seconds: 8)
        ? incomingTimeout
        : const Duration(seconds: 8);
    inc.timeoutTimer = Timer(watchdogTimeout, () {
      if (inc.bytesReceived == 0) {
        debugPrint('[sync] incoming ${song.id} stalled at 0% ($watchdogTimeout watchdog); aborting');
        _track(_abortIncoming(peerId, song.id));
      } else {
        inc.timeoutTimer = Timer(incomingTimeout, () {
          inc.timeoutTimer = null;
          debugPrint('[sync] incoming ${song.id} timed out; aborting');
          _track(_abortIncoming(peerId, song.id));
        });
      }
    });
    _incoming[song.id] = inc;
    if (_inboundBatch != null && _inboundBatch!.isDownload) {
      _inboundBatch!.activeSongTitle = song.title;
      _inboundBatch!.activeTotalBytes = song.size;
      _inboundBatch!.activeBytes = 0;
    }
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
      inc.raf.setPositionSync(index * chunkSize);
      inc.raf.writeFromSync(payload);
      inc.bytesReceived += payload.length;
    } catch (e) {
      debugPrint('[sync] error writing chunk for $songId: $e');
    }

    inc.timeoutTimer?.cancel();
    final chunkWatchdog = incomingTimeout < const Duration(seconds: 15)
        ? incomingTimeout
        : const Duration(seconds: 15);
    inc.timeoutTimer = Timer(chunkWatchdog, () {
      inc.timeoutTimer = null;
      debugPrint('[sync] incoming $songId transfer stalled mid-stream ($chunkWatchdog inactivity); aborting');
      _track(_abortIncoming(peerId, songId));
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
    if (_inboundBatch != null && _inboundBatch!.isDownload) {
      _inboundBatch!.activeBytes = inc.bytesReceived;
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
        inc.raf.flushSync();
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
      _markComplete(peerId, songId);
      onDownloaded?.call(inc.song.title);
      if (_inboundBatch != null && _inboundBatch!.isDownload) {
        _inboundBatch!.completedSongs++;
        _inboundBatch!.completedBytes += inc.song.size;
        _inboundBatch!.activeSongTitle = '';
        _inboundBatch!.activeBytes = 0;
        _inboundBatch!.activeTotalBytes = 0;
        if (_inboundBatch!.completedSongs >= _inboundBatch!.totalSongs) {
          _inboundBatch!.isDone = true;
          _inboundBatch!.dismissTimer?.cancel();
          _inboundBatch!.dismissTimer =
              Timer(const Duration(milliseconds: 2500), () {
            _inboundBatch = null;
            _flushNotify();
          });
        }
      }
      _flushNotify();
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
      _send(peerId, {'type': 'request_songs', 'ids': [songId]});
    }
  }

  Future<void> _abortIncoming(String peerId, String songId) async {
    final inc = _incoming.remove(songId);
    if (inc == null) return;
    inc.timeoutTimer?.cancel();
    inc.timeoutTimer = null;
    try {
      inc.raf.closeSync();
    } catch (_) {}
    try {
      if (inc.file.existsSync()) {
        inc.file.deleteSync();
      }
    } catch (_) {}
    if (_inboundBatch != null && _inboundBatch!.isDownload) {
      _inboundBatch!.activeSongTitle = '';
      _inboundBatch!.activeBytes = 0;
      _inboundBatch!.activeTotalBytes = 0;
    }
    _removeProgress(peerId, songId);
    _flushNotify();
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
    _inboundBatch?.dismissTimer?.cancel();
    _inboundBatch = null;
    _outboundBatch?.dismissTimer?.cancel();
    _outboundBatch = null;
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
