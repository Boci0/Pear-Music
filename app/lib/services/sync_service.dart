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

/// Transfers music files over the WebRTC data channels.
///
/// Protocol (all control messages are JSON text; file data is binary):
///   text  {type:'hello', deviceName}
///   text  {type:'manifest', songs:[Song.json]}
///   text  {type:'request_songs', ids:[...]}
///   text  {type:'file_meta', song: Song.json}
///   text  {type:'file_done', id}
///   text  {type:'file_error', id, message}
///   binary [magic 0x50][idLen u16][songId][chunkIndex u32][totalChunks u32][payload]
class SyncService extends ChangeNotifier {
  static const int chunkSize = 64 * 1024;

  /// How long an in-progress download may sit without finishing before it is
  /// aborted. A peer that dies mid-transfer (or a chunk that never arrives)
  /// must not leak an open file handle or a partial file forever — the song is
  /// re-requested and healed instead. Configurable for tests.
  final Duration incomingTimeout;

  /// How many times a failed finalize re-requests the song from the sender
  /// before giving up (prevents an infinite request/re-send loop when the
  /// sender genuinely cannot deliver).
  static const int maxFinalizeRetries = 2;

  /// While channels are attached, re-advertise our library every this often so
  /// a transfer that failed (dropped chunk, abort, sender hiccup) is re-requested
  /// automatically instead of waiting for a full reconnect + manifest exchange.
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

  /// Retry count per song for failed finalizes (see [maxFinalizeRetries]).
  final Map<String, int> _finalizeRetries = {};

  /// Transfers that just finished, kept around briefly so the UI can animate a
  /// "done" state before they disappear.
  final Map<String, TransferProgress> _completed = {};
  Timer? _completedTimer;

  Timer? _notifyTimer;
  bool _notifyQueued = false;

  /// Tracks in-flight async protocol handlers (file finalize, remote song
  /// deletions, playlist merges) so tests can await them via [idle], and so a
  /// slow/failing handler never surfaces as an unhandled async error.
  Future<void> _syncTail = Future<void>.value();

  /// Completes when every previously-dispatched protocol handler has finished
  /// (including its file writes). Tests await this before tearing down.
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

  /// A paired device deleted an original song we had a shared copy of; called
  /// AFTER the copy has been removed (id + title for the controller).
  Future<void> Function(String songId, String title)? onRemoteDeleted;

  /// A song finished downloading from a paired device (UI feedback).
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
    // E2E: advertise our ephemeral X25519 public key in `hello` so the peer
    // can derive a shared key to encrypt the relayed file stream. Only the
    // relay transport does this (WebRTC is already DTLS-encrypted).
    final e2ePub =
        channel is RelayDataChannel ? channel.signaling.e2ePubB64 : null;
    debugPrint('[sync] attachChannel $peerId (e2ePub present: ${e2ePub != null})');
    _send(peerId, {
      'type': 'hello',
      'deviceName': identity.deviceName,
      'e2ePub': ?e2ePub,
    });
    // Advertise our whole library; the peer asks for what it's missing.
    _send(peerId, {
      'type': 'manifest',
      'songs': library.songs.map((s) => s.toJson()).toList(),
    });
    // Advertise our playlists (and deletions) so both sides converge.
    _send(peerId, _playlistManifestMessage());
    notifyListeners();
    _startResyncTimer();
  }

  /// Keeps a periodic re-advertisement running while any channel is attached.
  void _startResyncTimer() {
    _resyncTimer?.cancel();
    _resyncTimer = Timer.periodic(resyncInterval, (_) => resyncNow());
  }

  /// Manually re-advertise our library + playlists to every online peer so anything the
  /// peer is still missing (a transfer that failed and exhausted its retries)
  /// is re-requested automatically. Clears stale send locks and retries.
  int resyncNow() {
    _sending.clear();
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
    if (_channels.isEmpty) {
      _resyncTimer?.cancel();
      _resyncTimer = null;
    }
    // Clean up partial downloads from this peer.
    final incomplete =
        _incoming.values.where((inc) => inc.peerId == peerId).toList();
    for (final inc in incomplete) {
      inc.timeoutTimer?.cancel();
      _incoming.remove(inc.song.id);
      _finalizeRetries.remove(inc.song.id);
      try {
        library.incomingFile(inc.song.id).deleteSync();
      } catch (_) {}
      _removeProgress(peerId, inc.song.id);
    }
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
        // E2E: if the peer advertised their X25519 public key, derive the
        // shared key used to encrypt relayed data between us and them.
        final e2ePub = msg['e2ePub'];
        final ch = _channels[peerId];
        if (e2ePub is String && ch is RelayDataChannel) {
          try {
            unawaited(ch.signaling.setPeerE2E(peerId, base64Decode(e2ePub)));
          } catch (_) {}
        }
        // The peer announced itself. Reply with our manifest so both sides
        // always exchange library state, even if our initial manifest was
        // sent before their channel handler was attached.
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
    final have = library.songs.map((s) => s.checksum).toSet();
    final missing = <String>[];
    for (final raw in rawSongs) {
      if (raw is! Map) continue;
      final song = Song.fromJson(Map<String, dynamic>.from(raw));
      if (song.sourceDeviceId == identity.deviceId) {
        // This is a song we originally owned and shared with this peer. If we
        // no longer have it, we deleted it: tell the peer to drop their copy
        // and never request it back. Without this, reconnecting peers re-download
        // our own deleted song and BOTH sides end up marked "Shared".
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
      if (!have.contains(song.checksum) && library.findById(song.id) == null) {
        missing.add(song.id);
      }
    }
    if (missing.isNotEmpty) {
      debugPrint('[sync][diag] requesting $missing.length missing songs from $peerId');
      _send(peerId, {'type': 'request_songs', 'ids': missing});
    } else {
      debugPrint('[sync][diag] nothing missing from $peerId (${rawSongs.length} advertised, have ${have.length})');
    }
  }

  void _onRequestSongs(String peerId, List<dynamic> ids) {
    for (final id in ids) {
      final song = library.findById(id as String);
      if (song != null) {
        unawaited(_sendFile(peerId, song));
      }
    }
  }

  // ---------- sending ----------

  /// Send a song to every online peer.
  Future<void> broadcastSong(Song song) async {
    for (final peerId in _channels.keys.toList()) {
      await _sendFile(peerId, song);
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
      final pending = <int>[];
      final reader = file.openRead();
      await for (final buffer in reader) {
        pending.addAll(buffer);
        while (pending.length >= chunkSize) {
          final piece = pending.sublist(0, chunkSize);
          pending.removeRange(0, chunkSize);
          await _sendChunk(channel, song.id, index, total, piece);
          index++;
          sentBytes += piece.length;
          _updateUploadProgress(peerId, song.id, sentBytes);
        }
      }
      if (pending.isNotEmpty || index < total) {
        await _sendChunk(channel, song.id, index, total, pending);
        index++;
        sentBytes += pending.length;
        _updateUploadProgress(peerId, song.id, sentBytes);
      }
      _send(peerId, {'type': 'file_done', 'id': song.id});
      _markComplete(peerId, song.id);
    } catch (e) {
      debugPrint('[sync] send failed $song: $e');
      _send(peerId, {'type': 'file_error', 'id': song.id, 'message': '$e'});
      _removeProgress(peerId, song.id);
    } finally {
      _sending.remove(sendKey);
    }
  }

  /// Key for the send-in-progress guard. Per-peer so two peers can receive the
  /// same song concurrently — keying by song id alone silently dropped the
  /// second peer's transfer.
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
    // Throttle so we never flood the channel's send buffer, but never stall
    // for long if the low-buffer event doesn't fire on this platform.
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
    // Duplicate?
    if (library.findById(song.id) != null ||
        library.songs.any((s) => s.checksum == song.checksum)) {
      debugPrint('[sync][diag] file_meta for ${song.title} already have; skipping');
      // We already have it; skip.
      _send(peerId, {'type': 'file_done', 'id': song.id});
      return;
    }
    final file = library.incomingFile(song.id);
    if (file.existsSync()) file.deleteSync();
    final raf = file.openSync(mode: FileMode.append);
    final inc = _IncomingFile(
      peerId: peerId,
      song: song,
      file: file,
      raf: raf,
    );
    // Abort the transfer if it stalls (the peer died / its `file_done` never
    // arrives / chunks stop coming). This is an INACTIVITY watchdog: it is
    // reset on every chunk in `_onBinary`, so a slow-but-progressing transfer
    // is never cut short — only a truly stalled one is cleaned up instead of
    // leaking an open file handle / partial file forever.
    inc.timeoutTimer = Timer(incomingTimeout, () {
      inc.timeoutTimer = null;
      debugPrint('[sync] incoming ${song.id} timed out; aborting');
      _track(_abortIncoming(peerId, song.id));
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
      debugPrint('[sync][diag] <- $peerId: binary frame NOT an envelope (len=${bytes.length}, first=${bytes.isEmpty ? 'none' : bytes[0]})');
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

    inc.raf.writeFromSync(payload);
    inc.bytesReceived += payload.length;
    // Reset the inactivity watchdog: any chunk means the transfer is alive.
    // A fixed total timeout could abort a large song on a slow link, so this
    // only fires when the transfer stalls (the peer died / chunks stopped
    // arriving) — then the partial download is cleaned up, not leaked.
    inc.timeoutTimer?.cancel();
    inc.timeoutTimer = Timer(incomingTimeout, () {
      inc.timeoutTimer = null;
      debugPrint('[sync] incoming $songId timed out; aborting');
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
    if (index == total - 1) {
      inc.completeChunks = true;
    }
    // Coalesce per-chunk progress into at most one notify per ~100 ms.
    // Notifying on every 64 KB chunk made every screen rebuild dozens of
    // times per second during a transfer, which caused visible jank.
    _throttledNotify();
  }

  /// Emits at most one [notifyListeners] per ~100 ms window. Progress updates
  /// arrive for every chunk; coalescing them keeps the UI smooth without
  /// dropping the final state (the last pending notify always fires).
  void _throttledNotify() {
    if (_notifyQueued) return;
    _notifyQueued = true;
    _notifyTimer ??= Timer(const Duration(milliseconds: 100), () {
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
      inc.raf.closeSync();
      final length = await inc.file.length();
      if (length != inc.song.size) {
        throw Exception('size mismatch: got $length, expected ${inc.song.size}');
      }
      // Verify the bytes we actually received match what the sender claimed,
      // instead of trusting `inc.song.checksum` at face value. A same-length
      // corruption (or a sender that mislabels a file) would otherwise be
      // silently accepted and stored under an unverified checksum forever.
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
      _finalizeRetries.remove(songId);
      _markComplete(peerId, songId);
      onDownloaded?.call(inc.song.title);
    } catch (e) {
      debugPrint('[sync] finalize failed $songId: $e');
      try {
        await inc.file.delete();
      } catch (_) {}
      _removeProgress(peerId, songId);
      // Self-heal: a failed finalize almost always means a chunk was dropped
      // (a lost relay_ack, a mis-routed frame, or a stale E2E key raced the
      // re-derivation). Re-request the song from the sender (up to
      // [maxFinalizeRetries] times) so the transfer retries instead of
      // silently vanishing until the next reconnect + manifest exchange.
      final retries = (_finalizeRetries[songId] ?? 0) + 1;
      if (retries <= maxFinalizeRetries) {
        _finalizeRetries[songId] = retries;
        debugPrint(
            '[sync] re-requesting $songId from $peerId (attempt $retries/$maxFinalizeRetries)');
        _send(peerId, {'type': 'request_songs', 'ids': [songId]});
      } else {
        _finalizeRetries.remove(songId);
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
    try {
      inc.raf.closeSync();
      await inc.file.delete();
    } catch (_) {}
    _removeProgress(peerId, songId);
  }

  // ---------- helpers ----------

  void _send(String peerId, Map<String, dynamic> msg) {
    final channel = _channels[peerId];
    if (channel == null) return;
    try {
      // Swallow async send errors (e.g. sending on a channel that closed mid
      // transfer) so they can never crash the app.
      channel.send(RTCDataChannelMessage(jsonEncode(msg))).catchError((Object e) {
        debugPrint('[sync] send failed: $e');
      });
    } catch (_) {}
  }

  Uint8List _buildEnvelope(
      String songId, int index, int total, List<int> payload) {
    final idBytes = utf8.encode(songId);
    final out = BytesBuilder(copy: false);
    out.addByte(0x50);
    out.addByte((idBytes.length >> 8) & 0xff);
    out.addByte(idBytes.length & 0xff);
    out.add(idBytes);
    out.add(_uint32(index));
    out.add(_uint32(total));
    out.add(payload);
    return out.toBytes();
  }

  List<int> _uint32(int value) => [
        (value >> 24) & 0xff,
        (value >> 16) & 0xff,
        (value >> 8) & 0xff,
        value & 0xff,
      ];

  int _readUint32(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  void _setProgress(TransferProgress p) {
    _transfers[p.key] = p;
    _flushNotify();
  }

  void _removeProgress(String peerId, String songId) {
    _transfers.removeWhere((k, v) => v.peerId == peerId && v.songId == songId);
    _flushNotify();
  }

  /// Move a finished transfer into the short-lived "completed" set so the UI
  /// can flash a success state before it disappears.
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
    _completedTimer?.cancel();
    _completedTimer = Timer(const Duration(milliseconds: 1600), () {
      _completed.clear();
      _flushNotify();
    });
  }

  /// Throttled live progress for an upload (the send loop updates per chunk).
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

  /// Tell every online peer that we deleted an original song (sourceDeviceId
  /// null) so they drop their shared copy. Songs we merely received are never
  /// broadcast — the origin owns them. Offline peers are reconciled on the next
  /// manifest exchange instead.
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

  /// A peer deleted an original we had a shared copy of: remove the copy and
  /// notify the controller. Local originals are never touched (ids are unique
  /// per logical file, but this guard makes deleting our own files impossible).
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

  /// Broadcast a playlist change (create / rename / add / remove / reorder) to
  /// every online peer.
  void broadcastPlaylistUpsert(Playlist playlist) {
    for (final peerId in _channels.keys.toList()) {
      _send(peerId, {'type': 'playlist_upsert', 'playlist': playlist.toJson()});
    }
  }

  /// Broadcast a playlist deletion to every online peer.
  void broadcastPlaylistDelete(String id, DateTime at) {
    for (final peerId in _channels.keys.toList()) {
      _send(peerId, {
        'type': 'playlist_delete',
        'id': id,
        'at': at.toIso8601String(),
      });
    }
  }

  Map<String, dynamic> _playlistManifestMessage() => {
        'type': 'playlist_manifest',
        'playlists': library.playlists.map((pl) => pl.toJson()).toList(),
        'deleted': {
          for (final e in library.deletedPlaylistsAt.entries)
            e.key: e.value.toIso8601String(),
        },
      };

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
    // Merge; echo back any of OUR playlists that are newer than the peer's.
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
    for (final inc in _incoming.values) {
      inc.timeoutTimer?.cancel();
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

  /// Aborts this download if it never finishes (see
  /// [SyncService.incomingTimeout]). Cancelled on finalize/abort/detach.
  Timer? timeoutTimer;

  _IncomingFile({
    required this.peerId,
    required this.song,
    required this.file,
    required this.raf,
  });
}
