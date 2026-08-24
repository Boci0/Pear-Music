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
  static const int chunkSize = 128 * 1024;

  final Duration incomingTimeout;
  static const int maxFinalizeRetries = 2;
  static const Duration resyncInterval = Duration(seconds: 45);

  /// Dynamic resync back-off: when every connected peer reports zero missing
  /// songs, stretch the interval by this many multiples of [resyncInterval]
  /// (45s -> 90s -> ... capped so an idle pair never polls faster than ~5
  /// minutes). Reset to 1 on new channels or local library changes.
  int _resyncBackoffSteps = 1;
  static const int _maxResyncBackoffSteps = 6;
  /// Per-peer flag: last manifest exchange found nothing missing.
  final Set<String> _peersInSync = {};

  final IdentityService identity;
  final LibraryService library;

  SyncService({
    required this.identity,
    required this.library,
    this.incomingTimeout = const Duration(seconds: 120),
  }) {
    // Any local library change invalidates the lightweight manifest
    // fingerprint and resets the resync back-off so peers hear about the
    // change on the next (short-interval) tick.
    library.addListener(_onLibraryChanged);
  }

  void _onLibraryChanged() {
    _cachedFingerprint = null;
    _resetResyncBackoff();
  }

  Timer? _resyncTimer;

  final Map<String, RTCDataChannel> _channels = {};
  /// Lightweight per-peer "manifest changed" markers (`id|checksum|size`
  /// fingerprints, NO artwork). Compared before any jsonEncode of the full
  /// manifest so routine resyncs skip both serialisation and transmission
  /// when nothing changed — base64 artwork made full-manifest encoding a
  /// heavy, repeated CPU cost after transfers.
  final Map<String, String> _lastFingerprintSent = {};
  String? _cachedFingerprint;
  final Map<String, _IncomingFile> _incoming = {};
  final Map<String, bool> _sending = {};
  final Map<String, TransferProgress> _transfers = {};
  final Map<String, TransferProgress> _completed = {};
  /// Failed-verification attempts per song id. Without a cap, a song whose
  /// checksum never matches is re-requested forever — two devices ping-pong
  /// the same file nonstop (constant CPU/network/battery) until restart.
  final Map<String, int> _finalizeAttempts = {};
  /// Last time a song was re-requested after a failed finalize, so periodic
  /// resyncs can't hammer the same failing files repeatedly.
  final Map<String, DateTime> _lastRequestAt = {};
  static const Duration _requestCooldown = Duration(minutes: 2);
  Timer? _completedTimer;

  _SyncBatch? _inboundBatch;
  _SyncBatch? _outboundBatch;

  Timer? _notifyTimer;
  bool _notifyQueued = false;
  bool _disposed = false;
  Timer? _watchdogTimer;

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
    // New channel connection: back to the fast 45s cadence.
    _resetResyncBackoff();
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
      // Marks this as an INITIAL connection hello so the peer replies with a
      // forced manifest — a previous identical manifest may still have been
      // lost before its handler was attached. Routine resync hellos never
      // set this flag and therefore never force a full re-encode/send.
      'initial': true,
    });
    _sendManifest(peerId, force: true);
    _send(peerId, _playlistManifestMessage());
  }

  /// Serialise + send the manifest to [peerId].
  ///
  /// Cost control (v1.6.9): a full manifest carries base64 artwork per song,
  /// so jsonEncode-ing it on every routine tick was a large recurring CPU
  /// spike after transfers finished. We first compare a lightweight
  /// fingerprint (`id|checksum|size`, no artwork): when [force] is false and
  /// the fingerprint matches what this peer last received, we skip BOTH the
  /// encode AND the send entirely.
  ///
  /// [force] is reserved for initial channel connections and explicit
  /// requests — a previously "identical" manifest may have been lost (e.g.
  /// sent before the peer attached its handler), so those must resend.
  void _sendManifest(String peerId, {bool force = false}) {
    final fp = _manifestFingerprint();
    if (!force && _lastFingerprintSent[peerId] == fp) return;
    _lastFingerprintSent[peerId] = fp;
    final json = jsonEncode({
      'type': 'manifest',
      // Artwork is stripped from wire manifests: matching only needs
      // identity fields. Cover art still reaches peers via file_meta.
      'songs': library.songs.map(_manifestSongJson).toList(),
    });
    final channel = _channels[peerId];
    if (channel == null) return;
    try {
      channel.send(RTCDataChannelMessage(json)).catchError((Object e) {
        debugPrint('[sync] send failed: $e');
      });
    } catch (_) {}
  }

  /// Artwork-free JSON for one song in a wire manifest.
  Map<String, dynamic> _manifestSongJson(Song s) {
    final j = s.toJson();
    j.remove('artwork');
    return j;
  }

  /// Cheap library fingerprint WITHOUT artwork: `id|checksum|size` per song.
  /// O(n) small-string work vs jsonEncode-ing every base64 cover image.
  String _manifestFingerprint() {
    final cached = _cachedFingerprint;
    if (cached != null) return cached;
    final buf = StringBuffer();
    for (final s in library.songs) {
      buf
        ..write(s.id)
        ..write('|')
        ..write(s.checksum)
        ..write('|')
        ..write(s.size)
        ..write(';');
    }
    return _cachedFingerprint = buf.toString();
  }

  void _startResyncTimer() {
    _scheduleResyncTick();
    _startWatchdogIfTransferring();
  }

  /// Self-rescheduling timer honouring the dynamic back-off: interval is
  /// `resyncInterval * _resyncBackoffSteps`, capped at ~5 minutes. Using a
  /// plain Timer (not Timer.periodic) lets each tick adopt the current
  /// back-off without leaking a fixed-cadence timer forever.
  void _scheduleResyncTick() {
    _resyncTimer?.cancel();
    final seconds =
        (resyncInterval.inSeconds * _resyncBackoffSteps).clamp(45, 300);
    _resyncTimer = Timer(Duration(seconds: seconds), () {
      resyncNow();
      if (_channels.isNotEmpty && !_disposed) _scheduleResyncTick();
    });
  }

  void _resetResyncBackoff() {
    if (_resyncBackoffSteps == 1) return;
    _resyncBackoffSteps = 1;
    if (_channels.isNotEmpty && !_disposed) _scheduleResyncTick();
  }

  /// Called when a peer's manifest exchange found zero missing songs. Only
  /// stretches the cadence once ALL connected peers are in sync.
  void _notePeerInSync(String peerId) {
    _peersInSync.add(peerId);
    for (final id in _channels.keys) {
      if (!_peersInSync.contains(id)) return;
    }
    if (_resyncBackoffSteps < _maxResyncBackoffSteps) {
      _resyncBackoffSteps++;
    }
    _scheduleResyncTick();
  }

  void _notePeerOutOfSync(String peerId) {
    _peersInSync.remove(peerId);
    _resetResyncBackoff();
  }

  /// Safety watchdog while downloads are in flight. Started lazily by
  /// [_startIncoming] and cancelled by [_maybeEnterIdle] so an app that is
  /// not transferring has ZERO periodic timers beyond the (backed-off)
  /// resync tick.
  void _startWatchdogIfTransferring() {
    if (_watchdogTimer != null || _incoming.isEmpty) return;
    _watchdogTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final inc in _incoming.values.toList()) {
        if (now - inc.lastChunkTime > incomingTimeout.inMilliseconds) {
          debugPrint(
              '[sync] incoming ${inc.song.id} stalled (${now - inc.lastChunkTime}ms > ${incomingTimeout.inMilliseconds}ms); aborting');
          _track(_abortIncoming(inc.peerId, inc.song.id));
        }
      }
    });
  }

  /// Keep LibraryService.index saves deferred while any transfer batch is
  /// mid-flight; called after every batch state mutation.
  void _updateDeferSaves() {
    library.deferIndexSaves =
        (_inboundBatch != null && !_inboundBatch!.isDone) ||
            (_outboundBatch != null && !_outboundBatch!.isDone);
  }

  /// True-idle recovery: called after batch/transfer state settles. When no
  /// files are incoming or sending and both batches are done, cancel the
  /// watchdog, clear completed-transfer maps and log a single summary line —
  /// the process then returns to a genuinely idle event loop instead of
  /// burning CPU until restart.
  void _maybeEnterIdle() {
    if (_incoming.isNotEmpty || _sending.isNotEmpty) return;
    if (_inboundBatch != null && !_inboundBatch!.isDone) return;
    if (_outboundBatch != null && !_outboundBatch!.isDone) return;
    // Safety net: never stay in deferred-save mode once everything settled.
    _updateDeferSaves();
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    if (_completed.isNotEmpty || _transfers.isNotEmpty) {
      _completed.clear();
      _transfers.clear();
      _completedTimer?.cancel();
      _completedTimer = null;
    }
    debugPrint('[sync] idle: hashJobs pending handled by LibraryService; '
        'incoming=${_incoming.length} sending=${_sending.length} '
        'transfers=${_transfers.length} completed=${_completed.length}');
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
      _sendManifest(peerId);
      _send(peerId, _playlistManifestMessage());
      _send(peerId, {'type': 'request_manifest'});
    }
    return count;
  }

  void detachChannel(String peerId) {
    _channels.remove(peerId);
    _sendQueues.remove(peerId);
    _lastFingerprintSent.remove(peerId);
    _peersInSync.remove(peerId);
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
    _finalizeAttempts.removeWhere((k, _) => k.startsWith('$peerId|'));

    if (_channels.isEmpty) {
      _resyncTimer?.cancel();
      _resyncTimer = null;
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      _inboundBatch?.dismissTimer?.cancel();
      _inboundBatch = null;
      _outboundBatch?.dismissTimer?.cancel();
      _outboundBatch = null;
      _updateDeferSaves();
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
        _startIncoming(peerId, msg['song'] as Map<String, dynamic>,
            chunkSize: (msg['chunkSize'] as num?)?.toInt() ?? chunkSize);
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
        // Explicit ask, but an UNCHANGED library must not be re-encoded and
        // re-sent on every tick — that was a recurring multi-hundred-KB
        // jsonEncode on both peers forever (post-transfer CPU never settled).
        // Gate by fingerprint; force only if we have NEVER sent this peer a
        // manifest (fresh attach / earlier one may have been lost).
        _sendManifest(peerId, force: !_lastFingerprintSent.containsKey(peerId));
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
          // Echo the initial flag so the ORIGINAL connector gets a forced
          // manifest reply; routine resync hellos stay fingerprint-gated.
          'initial': msg['initial'] == true,
        });
      }
    }
    // Routine resync hellos (ack:true) reply NON-forced: if our library is
    // unchanged the fingerprint check skips the encode + send entirely.
    _sendManifest(peerId, force: msg['initial'] == true);
    _send(peerId, _playlistManifestMessage());
  }

  void _onManifest(String peerId, List<dynamic> rawSongs) {
    // Build O(1) lookup structures once instead of scanning the whole library
    // per advertised song (was O(n*m) with a sync disk stat per comparison).
    final localById = <String, Song>{};
    final checksumsWithFiles = <String>{};
    for (final s in library.songs) {
      localById[s.id] = s;
      if (library.hasSongFile(s)) {
        checksumsWithFiles.add(s.checksum);
      }
    }

    final missingSongs = <Song>[];
    for (final raw in rawSongs) {
      if (raw is! Map) continue;
      final song = Song.fromJson(Map<String, dynamic>.from(raw));
      if (song.sourceDeviceId == identity.deviceId) {
        if (!localById.containsKey(song.id)) {
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
      final localMatch = localById[song.id];
      final hasMatchingSong = (localMatch != null &&
              library.hasSongFile(localMatch)) ||
          checksumsWithFiles.contains(song.checksum);

      final isActivelyDownloading = _incoming.containsKey(song.id);

      if (!hasMatchingSong && !isActivelyDownloading) {
        missingSongs.add(song);
      }
    }
    if (missingSongs.isNotEmpty) {
      // Something to fetch: we are NOT in sync. Drop back to the fast resync
      // cadence until both peers report complete libraries again.
      _notePeerOutOfSync(peerId);
      debugPrint(
          '[sync][diag] requesting ${missingSongs.length} missing songs from $peerId');
      _inboundBatch?.dismissTimer?.cancel();
      final totalBytes = missingSongs.fold<int>(0, (sum, s) => sum + s.size);
      _inboundBatch = _SyncBatch(
        totalSongs: missingSongs.length,
        totalBytes: totalBytes,
        isDownload: true,
      );
      // Safety watchdog: if the sender never sends file_meta within 12s, retry resync
      _inboundBatch!.dismissTimer = Timer(const Duration(seconds: 12), () {
        if (_inboundBatch != null &&
            _inboundBatch!.isDownload &&
            _inboundBatch!.activeBytes == 0 &&
            _inboundBatch!.completedSongs == 0) {
          debugPrint('[sync] inbound batch stalled with no file_meta; retrying manifest exchange');
          resyncNow();
        }
      });
      // Defer artwork-heavy index encodes until the batch finishes.
      _updateDeferSaves();
      _send(peerId, {
        'type': 'request_songs',
        'ids': missingSongs.map((s) => s.id).toList(),
      });
      _flushNotify();
    } else {
      debugPrint(
          '[sync][diag] nothing missing from $peerId (${rawSongs.length} advertised)');
      // Peer has nothing we need — allow the resync cadence to stretch.
      _notePeerInSync(peerId);
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
      final songId = id as String;
      final song = library.findById(songId);
      if (song != null) {
        requestedSongs.add(song);
      } else {
        _send(peerId, {
          'type': 'file_error',
          'id': songId,
          'message': 'Song not found in library index',
        });
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
      // Defer artwork-heavy index encodes until the batch finishes.
      _updateDeferSaves();
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

    _send(peerId, {
      'type': 'file_meta',
      'song': song.toJson(),
      'chunkSize': chunkSize,
    });

    try {
      // Verify against real disk before sending (cache may be stale).
      if (!await library.verifySongFile(song)) {
        throw Exception('local file missing');
      }
      final file = library.songFile(song);
      final fileSize = await file.length();
      if (fileSize != song.size && song.size > 0) {
        throw Exception('local file size mismatch ($fileSize vs ${song.size})');
      }
      final total = fileSize == 0 ? 1 : (fileSize / chunkSize).ceil();
      var index = 0;
      var sentBytes = 0;

      // One reusable envelope buffer for the whole file instead of a fresh
      // ~128KB allocation per chunk (~1GB of GC garbage per GB transferred,
      // which kept the GC — and UI jank — running long after the transfer).
      final idLen = utf8.encode(song.id).length;
      final envelope = Uint8List(1 + 2 + idLen + 8 + chunkSize);

      final raf = await file.open(mode: FileMode.read);
      try {
        while (sentBytes < fileSize) {
          final toRead = (fileSize - sentBytes) > chunkSize
              ? chunkSize
              : (fileSize - sentBytes);
          final piece = await raf.read(toRead);
          if (piece.isEmpty) break;
          await _sendChunk(channel, song.id, index, total, piece,
              envelope: envelope);
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
          _updateDeferSaves();
          _outboundBatch!.dismissTimer?.cancel();
          _outboundBatch!.dismissTimer =
              Timer(const Duration(milliseconds: 2500), () {
            _outboundBatch = null;
            _updateDeferSaves();
            _flushNotify();
            _maybeEnterIdle();
          });
        }
      }
      _flushNotify();
    } catch (e) {
      debugPrint('[sync] send failed $song: $e');
      _send(peerId, {'type': 'file_error', 'id': song.id, 'message': '$e'});
      if (_outboundBatch != null && !_outboundBatch!.isDownload) {
        _outboundBatch!.completedSongs++;
        _outboundBatch!.activeSongTitle = '';
        _outboundBatch!.activeBytes = 0;
        _outboundBatch!.activeTotalBytes = 0;
        if (_outboundBatch!.completedSongs >= _outboundBatch!.totalSongs) {
          _outboundBatch!.isDone = true;
          _updateDeferSaves();
          _outboundBatch!.dismissTimer?.cancel();
          _outboundBatch!.dismissTimer =
              Timer(const Duration(milliseconds: 2500), () {
            _outboundBatch = null;
            _updateDeferSaves();
            _flushNotify();
            _maybeEnterIdle();
          });
        }
      }
      _removeProgress(peerId, song.id);
    } finally {
      _sending.remove(sendKey);
      // Sending side settled: if everything else is quiet too, go idle.
      _maybeEnterIdle();
    }
  }

  String _sendKey(String peerId, String songId) => '$peerId|$songId';

  Future<void> _sendChunk(
    RTCDataChannel channel,
    String songId,
    int index,
    int total,
    List<int> payload, {
    Uint8List? envelope,
  }) async {
    final frame = envelope != null
        ? _fillEnvelope(envelope, songId, index, total, payload)
        : _buildEnvelope(songId, index, total, payload);
    await channel.send(RTCDataChannelMessage.fromBinary(frame));

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

  void _startIncoming(String peerId, Map<String, dynamic> songJson,
      {int chunkSize = SyncService.chunkSize}) {
    final song = Song.fromJson(songJson);
    final existingLocal = library.findById(song.id);
    final hasMatchingFile = (existingLocal != null &&
            library.hasSongFile(existingLocal)) ||
        library.songs.any(
          (s) =>
              s.id != song.id &&
              s.checksum == song.checksum &&
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
      chunkSize: chunkSize,
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
    // Lazily (re)arm the stall watchdog now that a download is in flight.
    _startWatchdogIfTransferring();
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
    // Zero-copy views: chunks arrive at high frequency, and copying the
    // ~128KB payload (plus decoding the id string) per chunk on the UI
    // isolate adds up to visible jank during large transfers.
    final idBytes = Uint8List.sublistView(bytes, off, off + idLen);
    final songId = _decodeSongId(idBytes);
    off += idLen;
    final index = _readUint32(bytes, off);
    off += 4;
    final total = _readUint32(bytes, off);
    off += 4;
    final payload = Uint8List.sublistView(bytes, off);

    final inc = _incoming[songId];
    if (inc == null) {
      debugPrint('[sync][diag] <- $peerId: chunk for UNKNOWN song $songId idx=$index/$total dropped');
      return;
    }
    if (index == 0 || index == total - 1) {
      debugPrint('[sync][diag] <- $peerId: chunk $songId idx=$index/$total (${payload.length} bytes)');
    }

    try {
      // Fast path: sequential append when chunks arrive in order (the common
      // case). Avoids a seek syscall per chunk. Out-of-order chunks fall back
      // to an absolute seek so correctness is preserved either way.
      if (index == inc.nextIndex) {
        inc.raf.writeFromSync(payload);
        inc.nextIndex++;
      } else {
        inc.raf.setPositionSync(index * inc.chunkSize);
        inc.raf.writeFromSync(payload);
        if (index >= inc.nextIndex) inc.nextIndex = index + 1;
      }
      inc.bytesReceived += payload.length;
      inc.lastChunkTime = DateTime.now().millisecondsSinceEpoch;
    } catch (e) {
      debugPrint('[sync] error writing chunk for $songId: $e');
    }

    final progress = _transfers['$peerId|$songId'];
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
    if (_disposed || _notifyQueued) return;
    _notifyQueued = true;
    _notifyTimer ??= Timer(const Duration(milliseconds: 200), () {
      _notifyQueued = false;
      _notifyTimer = null;
      if (!_disposed) {
        notifyListeners();
      }
    });
  }

  void _flushNotify() {
    if (_disposed) return;
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
      _finalizeAttempts.remove(songId);
      onDownloaded?.call(inc.song.title);
      if (_inboundBatch != null && _inboundBatch!.isDownload) {
        _inboundBatch!.completedSongs++;
        _inboundBatch!.completedBytes += inc.song.size;
        _inboundBatch!.activeSongTitle = '';
        _inboundBatch!.activeBytes = 0;
        _inboundBatch!.activeTotalBytes = 0;
        if (_inboundBatch!.completedSongs >= _inboundBatch!.totalSongs) {
          _inboundBatch!.isDone = true;
          // Lift the deferral BEFORE the flush so this encode actually runs.
          _updateDeferSaves();
          await library.flushSaveIndex();
          library.flushNotify();
          _inboundBatch!.dismissTimer?.cancel();
          _inboundBatch!.dismissTimer =
              Timer(const Duration(milliseconds: 2500), () {
            _inboundBatch = null;
            _updateDeferSaves();
            _flushNotify();
            _maybeEnterIdle();
          });
        }
      }
      // Coalesce: during a batch this fires per song; an immediate notify per
      // completion hammers the UI. The batch-end path flushes explicitly.
      _throttledNotify();
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
      // Retry cap + cooldown: without them a persistently-failing song is
      // re-requested forever (nonstop CPU + network until the app restarts).
      final attempts = (_finalizeAttempts[songId] ?? 0) + 1;
      _finalizeAttempts[songId] = attempts;
      final lastAt = _lastRequestAt[songId];
      final cooldownOk = lastAt == null ||
          DateTime.now().difference(lastAt) > _requestCooldown;
      if (attempts <= maxFinalizeRetries && cooldownOk) {
        _lastRequestAt[songId] = DateTime.now();
        debugPrint('[sync] re-requesting $songId '
            '(attempt $attempts/${maxFinalizeRetries + 1})');
        _send(peerId, {'type': 'request_songs', 'ids': [songId]});
      } else {
        debugPrint('[sync] giving up on $songId after $attempts failed '
            'verifications; it will retry on the next resync/reconnect');
        _finalizeAttempts.remove(songId);
      }
    }
  }

  Future<void> _abortIncoming(String peerId, String songId) async {
    final inc = _incoming.remove(songId);
    if (inc != null) {
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
    }
    if (_inboundBatch != null && _inboundBatch!.isDownload) {
      _inboundBatch!.activeSongTitle = '';
      _inboundBatch!.activeBytes = 0;
      _inboundBatch!.activeTotalBytes = 0;
      _inboundBatch!.completedSongs++;
      if (_inboundBatch!.completedSongs >= _inboundBatch!.totalSongs) {
        _inboundBatch!.isDone = true;
        _inboundBatch!.dismissTimer?.cancel();
        _inboundBatch!.dismissTimer =
            Timer(const Duration(milliseconds: 2500), () {
          _inboundBatch = null;
          _updateDeferSaves();
          _flushNotify();
          _maybeEnterIdle();
        });
      }
    }
    _removeProgress(peerId, songId);
    _flushNotify();
    // Aborts settle the receiving side; check for full idle.
    _maybeEnterIdle();
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
    return _fillEnvelope(
        Uint8List(1 + 2 + utf8.encode(songId).length + 8 + payload.length),
        songId, index, total, payload);
  }

  /// Fills [out] with the chunk envelope and returns the used-length view.
  /// Reusing one buffer across a whole file avoids thousands of large
  /// short-lived allocations that kept the GC busy after transfers.
  Uint8List _fillEnvelope(Uint8List out, String songId, int index, int total,
      List<int> payload) {
    final idBytes = utf8.encode(songId);
    final idLen = idBytes.length;
    final totalLen = 1 + 2 + idLen + 4 + 4 + payload.length;
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
    return Uint8List.sublistView(out, 0, totalLen);
  }

  /// One-entry decode cache: consecutive chunks almost always belong to the
  /// same song, so the UTF-8 id decode runs once per song instead of once per
  /// chunk.
  Uint8List? _lastIdBytes;
  String? _lastId;

  String _decodeSongId(Uint8List idBytes) {
    final last = _lastIdBytes;
    if (last != null && last.length == idBytes.length) {
      var same = true;
      for (var i = 0; i < last.length; i++) {
        if (last[i] != idBytes[i]) {
          same = false;
          break;
        }
      }
      if (same) return _lastId!;
    }
    final decoded = utf8.decode(idBytes);
    _lastIdBytes = Uint8List.fromList(idBytes);
    _lastId = decoded;
    return decoded;
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
    _throttledNotify();
  }

  void _removeProgress(String peerId, String songId) {
    _transfers.removeWhere((k, v) => v.peerId == peerId && v.songId == songId);
    _throttledNotify();
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
    _throttledNotify();
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
    _disposed = true;
    library.removeListener(_onLibraryChanged);
    _resyncTimer?.cancel();
    _resyncTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
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
  /// Chunk size negotiated by the sender via file_meta.
  final int chunkSize;
  int bytesReceived = 0;
  /// Next chunk index expected in-order; enables seek-free sequential writes.
  int nextIndex = 0;
  bool completeChunks = false;
  Timer? timeoutTimer;
  int lastChunkTime = DateTime.now().millisecondsSinceEpoch;

  _IncomingFile({
    required this.peerId,
    required this.song,
    required this.file,
    required this.raf,
    this.chunkSize = SyncService.chunkSize,
  });
}