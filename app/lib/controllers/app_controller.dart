import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../models/peer_device.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/identity_service.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/relay_data_channel.dart';
import '../services/signaling_server.dart';
import '../services/signaling_service.dart';
import '../services/sync_service.dart';
import '../services/youtube_service.dart';

/// Central state + orchestration for the whole app.
///
/// Owns the services and translates signaling / sync / player events into a
/// simple state surface that the widgets render:
///   - connection status + paired devices list
///   - the music library
///   - in-flight transfer progress
///   - playback state
class AppController extends ChangeNotifier {
  final IdentityService identity;
  final LibraryService library;
  final SignalingService signaling;
  final SyncService sync;
  final PlayerService player;
  final YoutubeService youtube;

  /// Embedded signaling server (auto-started in main()). Lets this device
  /// host the relay on both Windows and Android without running Node.js.
  final SignalingServer server;

  AppController({
    required this.identity,
    required this.library,
    required this.signaling,
    required this.sync,
    required this.player,
    required this.youtube,
    required this.server,
  });

  /// True when this device's embedded server is listening (i.e. this device
  /// is the host other devices should point their server URL at).
  bool get isHostingServer => server.isRunning;

  /// The LAN address other devices should connect to, when hosting.
  String? get serverLanIp => server.lanIp;

  /// The default server URL this device uses when it hosts.
  String get localServerUrl => 'ws://localhost:${server.boundPort}';

  /// The address OTHER devices should use to reach this device's embedded
  /// server, when hosting. Null if not hosting or no LAN IP could be resolved.
  String? get hostServerUrl {
    if (!server.isRunning) return null;
    final ip = server.lanIp;
    if (ip == null) return null;
    return 'ws://$ip:${server.boundPort}';
  }

  final List<PeerDevice> _pairedDevices = [];
  List<PeerDevice> get pairedDevices => List.unmodifiable(_pairedDevices);

  /// Reliable sync channels to each peer (relayed through the server).
  final Map<String, RelayDataChannel> _relayChannels = {};

  /// Peer announced by the most recent `{t:'bin'}` relay marker; the next raw
  /// binary frame belongs to that peer.
  String? _pendingRelayBinaryFrom;

  /// Whether that pending raw binary frame is E2E-encrypted (from the marker).
  bool _pendingRelayBinaryEnc = false;

  List<Song> get songs => library.songs;

  String connectionStatus = 'offline'; // 'connecting' | 'connected' | 'offline'
  String? pendingPairingCode;

  final _messages = StreamController<String>.broadcast();
  Stream<String> get messages => _messages.stream;

  final List<StreamSubscription> _subs = [];
  final List<VoidCallback> _removeNotifierListeners = [];

  // ---------- lifecycle ----------

  Future<void> init() async {
    await library.init();
    await player.init();

    // NOTE: sync's notifyListeners() is deliberately NOT forwarded here.
    // Transfer progress fires up to ~10x/second while a file is syncing and
    // every listener of AppController (HomeScreen, PlayerBar, DevicesScreen,
    // ...) would rebuild on each tick — the main source of the app's jank.
    // The only widget that shows live progress (TransferList) subscribes to
    // SyncService directly, so the rest of the UI stays put during transfers.
    _removeNotifierListeners.addAll([
      () => library.removeListener(notifyListeners),
      () => player.removeListener(notifyListeners),
    ]);
    library.addListener(notifyListeners);
    player.addListener(notifyListeners);

    // Sync feedback: surface downloads and remote deletions to the user (the
    // "why did that song disappear?" problem), and stop playback if a song that
    // is currently playing was removed by its source device.
    sync.onDownloaded = (title) {
      _postMessage('Received "$title" from a paired device.');
    };
    sync.onRemoteDeleted = (id, title) async {
      if (player.currentSong?.id == id) {
        await player.stop();
      }
      _postMessage('Removed "$title": its source device deleted it.');
    };

    // File transfers go over the server relay (RelayDataChannel), not WebRTC
    // P2P — WebRTC data channels dropped ~0.4s after opening on phone hotspots
    // and the native channel could throw an unhandled exception (the black
    // screen during pairing). The WebRTC layer was removed entirely; the relay
    // is stable on every network.

    // Listen to the server.
    _subs.add(signaling.stream.listen(_onServerMessage));

    // IMPORTANT: do NOT block the first frame on the server connection.
    // A WebSocket connect has no timeout, so if the server is unreachable
    // (hotspot/server down) `await signaling.start()` could hold up runApp for
    // tens of seconds — the long black screen on launch that only cleared once
    // the connect finally failed. Start it in the background: the UI renders
    // immediately and flips to "offline" until the connection succeeds.
    unawaited(signaling.start());
    notifyListeners();
  }

  Future<void> disposeAll() async {
    for (final s in _subs) {
      await s.cancel();
    }
    for (final remove in _removeNotifierListeners) {
      remove();
    }
    sync.detachChannelAll();
    signaling.dispose();
    player.dispose();
    await server.stop();
    _messages.close();
    super.dispose();
  }

  // ---------- server message handling ----------

  Future<void> _onServerMessage(Map<String, dynamic> msg) async {
    switch (msg['type']) {
      case '_local':
        if (msg['event'] == 'binary') {
          // Raw relayed chunk body; route it to the peer announced by the most
          // recent {t:'bin'} marker.
          final bytes = msg['bytes'];
          final from = _pendingRelayBinaryFrom;
          if (bytes is Uint8List && from != null) {
            _relayChannels[from]?.handleRelayBinary(
              bytes,
              encrypted: _pendingRelayBinaryEnc,
            );
          }
          _pendingRelayBinaryEnc = false;
          break;
        }
        connectionStatus =
            msg['event'] == 'connected' ? 'connected' : 'offline';
        if (msg['event'] == 'connected') {
          // Ensure pairing list is fresh after (re)connect.
          signaling.getState();
        } else {
          _pendingRelayBinaryFrom = null;
          _pendingRelayBinaryEnc = false;
        }
        notifyListeners();
        break;

      case 'registered':
        signaling.getState();
        break;

      case 'state':
        unawaited(_applyPairings(msg['pairings'] as List? ?? []));
        break;

      case 'pairing_created':
        pendingPairingCode = msg['code'] as String?;
        notifyListeners();
        break;

      case 'paired':
        final peer = PeerDevice.fromJson(
          Map<String, dynamic>.from(msg['peer'] as Map),
        );
        _upsertPeer(peer);
        _postMessage('Paired with ${peer.deviceName}');
        await _reconcileConnections();
        break;

      case 'unpaired':
        final peer = PeerDevice.fromJson(
          Map<String, dynamic>.from(msg['peer'] as Map),
        );
        await _handlePeerGone(
          peer.deviceId,
          deviceName: peer.deviceName,
          explicit: true,
        );
        break;

      case 'signal':
        // WebRTC signaling is disabled: sync runs over the server relay, so we
        // never answer offers or build a native data channel. Creating one
        // caused the flutter_webrtc crash ("Cannot add new events after calling
        // close") → black screen the moment the P2P channel dropped.
        break;

      case 'relay':
        final from = msg['from'] as String?;
        final data = msg['data'];
        if (from == null || data is! Map) break;
        if (data['t'] == 'bin') {
          final legacy = data['d'];
          if (legacy is String) {
            // Legacy sender: a base64 chunk inline in the envelope.
            try {
              final bytes = base64Decode(legacy);
              _relayChannels[from]?.handleRelayBinary(
                Uint8List.fromList(bytes),
              );
            } catch (_) {}
          } else {
            // New protocol: the next raw binary frame belongs to this peer.
            _pendingRelayBinaryFrom = from;
            _pendingRelayBinaryEnc = data['e'] == 1;
          }
        } else {
          _relayChannels[from]?.handleRelay(
            Map<String, dynamic>.from(data),
          );
        }
        break;

      case 'peer_status':
        final peerId = msg['peerId'] as String;
        final online = msg['online'] == true;
        final idx =
            _pairedDevices.indexWhere((d) => d.deviceId == peerId);
        if (idx != -1) {
          _pairedDevices[idx] = _pairedDevices[idx].copyWith(online: online);
          notifyListeners();
        }
        await _reconcileConnections();
        break;

      case 'error':
        _postMessage(msg['message'] as String? ?? 'Server error');
        break;
    }
  }

  Future<void> _applyPairings(List<dynamic> raw) async {
    final incoming = <String, PeerDevice>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final peer = PeerDevice.fromJson(Map<String, dynamic>.from(item));
      incoming[peer.deviceId] = peer;
    }
    final pairedIds = incoming.keys.toSet();

    // 1) Peers we were paired with but that the server no longer lists were
    //    unpaired (explicitly, or the server lost the pairing on restart).
    //    Drop them from the list and clean up their channels + songs.
    final gone = _pairedDevices
        .where((d) => !pairedIds.contains(d.deviceId))
        .toList();
    _pairedDevices.removeWhere((d) => !pairedIds.contains(d.deviceId));
    for (final peer in gone) {
      await _handlePeerGone(peer.deviceId, deviceName: peer.deviceName);
    }

    // 2) Also remove shared songs whose source is no longer paired but that
    //    have no _pairedDevices entry left to trigger cleanup (e.g. stale from
    //    a previous session — the app was offline when the pairing ended, or
    //    the app launched after a server restart). A peer that is merely
    //    offline is still in the list, so its songs stay. Locally-added songs
    //    (sourceDeviceId == null) are never affected.
    final goneIds = gone.map((d) => d.deviceId).toSet();
    final staleSources = library.songs
        .map((s) => s.sourceDeviceId)
        .whereType<String>()
        .where((id) => !pairedIds.contains(id) && !goneIds.contains(id))
        .toSet();
    for (final sourceId in staleSources) {
      await _handlePeerGone(sourceId);
    }

    for (final entry in incoming.entries) {
      _upsertPeer(entry.value);
    }
    notifyListeners();
    unawaited(_reconcileConnections());
  }

  /// Reconcile the paired-device list (and prune shared songs) against the
  /// server's authoritative pairing `state`. Test hook for [_applyPairings].
  @visibleForTesting
  Future<void> applyPairings(List<dynamic> raw) => _applyPairings(raw);

  /// Tear down a device we are no longer paired with and delete every song it
  /// shared. Only songs whose [Song.sourceDeviceId] matches are removed —
  /// locally-added songs are never touched. Playback stops if the currently
  /// playing song came from this device. [deviceName] is used only for status
  /// messages (it may be unknown for stale sources with no peer entry).
  Future<void> _handlePeerGone(
    String deviceId, {
    String? deviceName,
    bool explicit = false,
  }) async {
    _pairedDevices.removeWhere((d) => d.deviceId == deviceId);
    _relayChannels.remove(deviceId);
    sync.detachChannel(deviceId);
    final removed = await library.removeAllFromSource(deviceId);
    if (player.currentSong != null &&
        player.currentSong!.sourceDeviceId == deviceId) {
      await player.stop();
    }
    final name = deviceName ?? 'an unpaired device';
    if (removed > 0) {
      _postMessage(
        explicit
            ? 'Unpaired from $name. Removed $removed shared song(s).'
            : 'No longer paired with $name. Removed $removed shared song(s).',
      );
    } else if (explicit) {
      _postMessage('Unpaired from $name.');
    }
    notifyListeners();
  }

  void _upsertPeer(PeerDevice peer) {
    final idx = _pairedDevices.indexWhere((d) => d.deviceId == peer.deviceId);
    if (idx == -1) {
      _pairedDevices.add(peer);
    } else {
      _pairedDevices[idx] = peer.copyWith(
        deviceName: peer.deviceName,
        online: peer.online || _pairedDevices[idx].online,
      );
    }
    notifyListeners();
  }

  /// Attach a reliable relay channel to every online paired peer.
  ///
  /// File sync goes through the server's WebSocket (stable everywhere). WebRTC
  /// P2P is left for a future optimization because it is unreliable on some
  /// networks (e.g. phone hotspots drop the UDP path seconds after opening).
  Future<void> _reconcileConnections() async {
    for (final peer in _pairedDevices) {
      if (!peer.online) {
        sync.detachChannel(peer.deviceId);
        _relayChannels.remove(peer.deviceId);
        continue;
      }
      if (sync.hasChannel(peer.deviceId)) continue;
      final relay =
          RelayDataChannel(peerId: peer.deviceId, signaling: signaling);
      _relayChannels[peer.deviceId] = relay;
      sync.attachChannel(peer.deviceId, relay);
    }
  }

  // ---------- pairing ----------

  Future<void> generatePairingCode() async {
    if (connectionStatus != 'connected') {
      _postMessage(
        'Not connected to the server. Set the server URL in Settings and tap Connect.',
      );
      return;
    }
    pendingPairingCode = null;
    notifyListeners();
    signaling.createPairing();
  }

  Future<void> joinWithCode(String code) async {
    if (connectionStatus != 'connected') {
      _postMessage(
        'Not connected to the server. Set the server URL in Settings and tap Connect.',
      );
      return;
    }
    signaling.pairWithCode(code.trim().toUpperCase());
  }

  Future<void> unpair(PeerDevice peer) async {
    // Ask the server to break the pairing; both devices get 'unpaired' and
    // each deletes the songs it received from the other.
    signaling.unpair(peer.deviceId);
  }

  // ---------- library ----------

  Future<void> addFilesFromPicker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final files = result.files
        .map((f) => File(f.path ?? ''))
        .where((f) => f.existsSync())
        .toList();
    if (files.isEmpty) return;
    final added = await library.addLocalFiles(files);
    for (final song in added) {
      unawaited(sync.broadcastSong(song));
    }
    if (added.isNotEmpty) {
      _postMessage(
        'Added ${added.length} song(s). Synced to ${sync.channelCount} device(s).',
      );
    }
  }

  Future<void> addDroppedFiles(List<File> files) async {
    if (files.isEmpty) return;
    final added = await library.addLocalFiles(files);
    for (final song in added) {
      unawaited(sync.broadcastSong(song));
    }
    if (added.isNotEmpty) {
      _postMessage(
        'Added ${added.length} dropped song(s). Synced to ${sync.channelCount} device(s).',
      );
    }
  }

  // ---------- playlists ----------

  List<Playlist> get playlists => library.playlists;

  Future<Playlist> createPlaylist(String name) async {
    final pl = await library.createPlaylist(name);
    sync.broadcastPlaylistUpsert(pl);
    return pl;
  }

  Future<void> deletePlaylist(String id) async {
    final at = await library.deletePlaylist(id);
    if (at != null) sync.broadcastPlaylistDelete(id, at);
  }

  Future<void> renamePlaylist(String id, String name) async {
    await library.renamePlaylist(id, name);
    final pl = library.findPlaylist(id);
    if (pl != null) sync.broadcastPlaylistUpsert(pl);
  }

  Future<bool> addSongToPlaylist(String playlistId, String songId) async {
    final added = await library.addSongToPlaylist(playlistId, songId);
    if (added) {
      final pl = library.findPlaylist(playlistId);
      if (pl != null) sync.broadcastPlaylistUpsert(pl);
    }
    return added;
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    await library.removeSongFromPlaylist(playlistId, songId);
    final pl = library.findPlaylist(playlistId);
    if (pl != null) sync.broadcastPlaylistUpsert(pl);
  }

  Future<void> reorderPlaylist(String playlistId, List<String> songIds) async {
    await library.setPlaylistSongIds(playlistId, songIds);
    final pl = library.findPlaylist(playlistId);
    if (pl != null) sync.broadcastPlaylistUpsert(pl);
  }

  /// Rip a song from a YouTube **or Spotify** link on THIS device, then sync
  /// it to peers. Returns `null` on success or a human-readable error message
  /// on failure (the dialog shows it inline). [onStatus] streams progress text;
  /// [onProgress] streams byte-level download progress; [cancel] aborts.
  ///
  /// The only downloader is **yt-dlp**: the binary bundled in the APK on
  /// Android, the installed binary on desktop (the built-in youtube_explode
  /// downloader and the Piped proxy were removed — both were unreliable /
  /// rate-limited on this network). Spotify audio is DRM-encrypted, but yt-dlp
  /// resolves Spotify links to their YouTube source itself.
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
    unawaited(sync.broadcastSong(song));
    _postMessage(
      'Added "${song.title}" (via yt-dlp) and synced to '
      '${sync.channelCount} device(s).',
    );
    return null;
  }

  /// Turn known YouTube/network errors into a short, actionable message.
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

  /// Play every song in [playlist] in order.
  Future<void> playPlaylist(Playlist playlist) async {
    final songs = [
      for (final id in playlist.songIds)
        if (library.findById(id) != null) library.findById(id)!,
    ];
    if (songs.isEmpty) {
      _postMessage('This playlist is empty.');
      return;
    }
    await player.playSong(songs.first, queue: songs);
  }

  /// Remove [song] from this device's library (and from any playlist). If it
  /// is the currently-playing song, playback stops first. Paired devices are
  /// told to drop their copy too — a peer only removes a song when its own copy
  /// is a *shared* one, so an original always survives. This also self-heals
  /// the stale "both sides marked Shared" state left by the pre-fix re-download
  /// bug: deleting the copy on either side cleans up the orphan on the other.
  Future<void> removeSong(Song song) async {
    if (player.currentSong?.id == song.id) {
      await player.stop();
    }
    await library.removeSong(song.id);
    sync.broadcastSongDeleted(song);
    _postMessage('Removed "${song.title}"');
  }

  // ---------- settings ----------

  Future<void> updateDeviceName(String name) async {
    await identity.setDeviceName(name);
    // Re-register so peers see the new name immediately.
    signaling.send({
      'type': 'register',
      'deviceId': identity.deviceId,
      'deviceName': identity.deviceName,
    });
    notifyListeners();
  }

  Future<void> updateServerUrl(String url) async {
    await identity.setServerUrl(url);
    sync.detachChannelAll();
    _pairedDevices.clear();
    pendingPairingCode = null;
    connectionStatus = 'connecting';
    notifyListeners();
    await signaling.stop();
    await signaling.start();
  }

  /// Smart Connect: switch to [url] (if different) and wait until this device
  /// is connected + registered with that server (up to ~20s). Returns true on
  /// success. Used by the QR flow so scanning a host's QR joins the right
  /// server automatically instead of requiring a manual URL edit.
  Future<bool> connectToServer(String url) async {
    final target = url.trim();
    if (target.isEmpty) return false;
    if (identity.serverUrl != target) {
      await updateServerUrl(target);
    }
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (connectionStatus == 'connected') return true;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return connectionStatus == 'connected';
  }

  // ---------- playback (delegated) ----------

  Future<void> playSong(Song song) => player.playSong(song);
  Future<void> togglePlayback() => player.toggle();
  Future<void> nextTrack() => player.next();
  Future<void> previousTrack() => player.previous();
  Future<void> toggleLoop() => player.toggleLoop();
  void toggleShuffle() => player.toggleShuffle();
  Future<void> seek(Duration d) => player.seek(d);
  Future<void> setVolume(double v) => player.setVolume(v);

  void _postMessage(String text) {
    if (!_messages.isClosed) _messages.add(text);
  }
}
