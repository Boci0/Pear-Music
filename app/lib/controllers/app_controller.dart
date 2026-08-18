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
import '../services/server_discovery.dart';
import '../services/signaling_server.dart';
import '../services/signaling_service.dart';
import '../services/sync_service.dart';
import '../services/youtube_search_service.dart';
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
        list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case SortOption.size:
        list.sort((a, b) => b.size.compareTo(a.size));
        break;
      case SortOption.dateAdded:
      default:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
        break;
    }
    return list;
  }

  final List<PeerDevice> _pairedDevices = [];
  List<PeerDevice> get pairedDevices => List.unmodifiable(_pairedDevices);

  /// Reliable sync channels to each peer (relayed through the server).
  final Map<String, RelayDataChannel> _relayChannels = {};

  /// Peers announced by `{t:'bin'}` relay markers that have not yet been
  /// matched to their raw binary frame, in arrival order (FIFO).
  ///
  /// This is a queue rather than a single slot because several peers can be
  /// relaying binary frames to us at the same time (e.g. two devices each
  /// sending a song). Each raw frame is paired with the OLDEST unmatched
  /// marker — the exact order the server relays them (the server forwards
  /// markers and frames in arrival order and the sender gates one frame in
  /// flight, so a single slot previously mis-routed frames from a second
  /// sender to the wrong peer, which failed decryption and dropped the chunk).
  ///
  /// Each marker records when it was queued. If the matching frame never
  /// arrives (the sender died mid-transfer, its connection dropped, or the
  /// server restarted), the stale marker would otherwise sit in the queue and
  /// get paired with the NEXT frame from a DIFFERENT peer — mis-routing it and
  /// dropping the chunk. Stale markers are therefore pruned before pairing and
  /// a peer's markers are dropped when that peer goes offline.
  final List<({String from, bool enc, DateTime at})> _pendingRelayBinaryMarkers =
      [];

  /// A binary chunk's marker and its frame travel back-to-back (the sender
  /// waits for the server's `relay_ack` before the next frame), so a marker
  /// that has sat unmatched for this long will never be matched — drop it
  /// instead of letting it steal the next peer's frame.
  static const _markerMaxAge = Duration(seconds: 30);

  /// Set while a smart pairing attempt is trying multiple servers, so the
  /// per-attempt `error` snackbars are suppressed in favour of one final result.
  bool _pairSmartActive = false;

  /// Set when the app is shutting down, to stop background work (auto-discovery)
  /// from touching a disposed controller.
  bool _closing = false;

  /// URLs we recently tried to connect to (as a client / after deferring to a
  /// host) and failed — typically a stale/wrong advertised LAN IP. Host election
  /// skips these for a short while so the defer→fail→take-over loop can't spin
  /// forever against an unreachable host (each cycle tears down channels and
  /// re-syncs songs, which reads as a "shaky" connection).
  final Map<String, DateTime> _unreachableHosts = {};
  static const Duration _unreachableCooldown = Duration(seconds: 30);

  // Faster host failover: when the host dies, a client takes over in ~6s (was
  // 25s); a starting client that can't reach its remembered host takes over in
  // ~5s (was 10s). A brief blip is fine — the returning host reclaims hosting
  // via periodic reconciliation, so the system settles on exactly one host.
  static const Duration _hostGrace = Duration(seconds: 5);
  static const Duration _failoverDelay = Duration(seconds: 6);
  Timer? _failoverTimer;
  Timer? _hostReconcileTimer;
  DateTime? _offlineSince;

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
    // P2P, WebRTC data channels dropped ~0.4s after opening on phone hotspots
    // and the native channel could throw an unhandled exception (the black
    // screen during pairing). The WebRTC layer was removed entirely; the relay
    // is stable on every network.

    // Listen to the server.
    _subs.add(signaling.stream.listen(_onServerMessage));

    // IMPORTANT: do NOT block the first frame on the server connection.
    // A WebSocket connect has no timeout, so if the server is unreachable
    // (hotspot/server down) `await signaling.start()` could hold up runApp for
    // tens of seconds, the long black screen on launch that only cleared once
    // the connect finally failed. Start it in the background: the UI renders
    // immediately and flips to "offline" until the connection succeeds.
    unawaited(_ensureConnection());
    notifyListeners();
  }

  /// Reset connection and re-trigger file transfer checks and manifest exchange with all devices.
  Future<int> forceSync() async {
    await signaling.restart();
    await _ensureConnection();
    await Future.delayed(const Duration(milliseconds: 1200));
    final count = sync.resyncNow();
    notifyListeners();
    return count;
  }

  /// Zero-config host election. The "last online" device is the host; every
  /// other device connects to it as a client. If I believe I'm the host, I
  /// first make sure no other device already took over while I was offline
  /// (then I defer to it), otherwise I host. If I'm a client and the host is
  /// unreachable, I take over as host automatically.
  Future<void> _ensureConnection() async {
    if (identity.isHost) {
      // I believe I'm the host. Before hosting, check whether another device
      // already took over as host while I was offline — if so, defer to it.
      // Skip hosts we recently failed to reach so we don't defer to a stale
      // URL, fail, take over, re-discover the same URL and loop forever.
      final others = _filterReachable(await discoverNearby());
      if (others.isNotEmpty) {
        debugPrint('[host] another host found (${others.first.url}); deferring');
        await identity.setIsHost(false);
        await updateServerUrl(others.first.url);
        return;
      }
      // No other host — I host (run my own server, connect to localhost).
      await _ensureLocalServer();
      final local = 'ws://localhost:${server.boundPort}';
      if (identity.serverUrl != local) {
        await updateServerUrl(local);
      } else {
        await signaling.start();
      }
      _scheduleHostReconcile();
      return;
    }
    // Client: connect to the remembered host; take over if it's unreachable.
    await signaling.start();
    await Future.delayed(_hostGrace);
    if (_closing || connectionStatus == 'connected') return;
    await _takeOverAsHost();
  }

  /// Make sure the embedded server is running (host role).
  Future<void> _ensureLocalServer() async {
    if (!server.isRunning) {
      try {
        await server.start();
      } catch (e) {
        debugPrint('[host] could not start local server: $e');
      }
    }
  }

  /// This device becomes the host (runs the server, connects to itself).
  Future<void> _takeOverAsHost() async {
    debugPrint('[host] taking over as host');
    _failoverTimer?.cancel();
    _failoverTimer = null;
    _offlineSince = null;
    await _ensureLocalServer();
    await identity.setIsHost(true);
    await updateServerUrl('ws://localhost:${server.boundPort}');
    _scheduleHostReconcile();
  }

  /// One-shot check shortly after becoming host: if a higher-priority host
  /// (smaller deviceId) is also online — e.g. two devices started at once —
  /// defer to it so there is always exactly one host. Also re-checks every 30s
  /// while hosting, so this device hands back to the original host as soon as
  /// it returns (host switching recovers fast in BOTH directions).
  ///
  /// Runs [_reconcileGhostPairings] on the same cadence: host election alone
  /// only makes ONE of two rival hosts defer (whichever has the lower-
  /// priority deviceId) — the other keeps hosting indefinitely and may never
  /// register with (and thus never reconcile against) a paired peer that's
  /// also independently hosting. Ghost-pairing cleanup can't wait for host
  /// election to converge, since for the "losing" side it may never converge.
  void _scheduleHostReconcile() {
    _hostReconcileTimer?.cancel();
    _hostReconcileTimer = null;
    // Fire once after a short grace (let the connection settle).
    // No periodic polling timer: topology and discovery are event-driven via
    // UDP multicast announcements when peers join, eliminating periodic sweeps.
    Timer(const Duration(seconds: 3), () => unawaited(_reconcileHostAndGhost()));
  }

  /// Single entry point for both host and ghost-pairing reconciliation.
  ///
  /// Both jobs need the same LAN scan result, so [discoverNearby] is called
  /// once and the result is passed to each — previously two independent scans
  /// ran back-to-back every 30s, doubling the connection storm on the router.
  Future<void> _reconcileHostAndGhost() async {
    if (_closing || !identity.isHost) return;
    final others = _filterReachable(await discoverNearby());
    await _reconcileHost(others);
    await _reconcileGhostPairings(others);
  }

  Future<void> _reconcileHost(List<DiscoveredServer> others) async {
    if (_closing || !identity.isHost) return;
    for (final host in others) {
      final otherId = host.deviceId;
      if (otherId != null && otherId.compareTo(identity.deviceId) < 0) {
        debugPrint('[host] higher-priority host ${host.url}; deferring');
        _hostReconcileTimer?.cancel();
        _hostReconcileTimer = null;
        await identity.setIsHost(false);
        await server.stop();
        await updateServerUrl(host.url);
        return;
      }
    }
  }

  /// Checks in with any PAIRED peer that is independently running its own
  /// server right now (a "split brain": we believe we're paired with it, but
  /// nothing has ever made either of us register with the other's server, so
  /// neither side's register-time pairing reconciliation has ever run
  /// against the other — see host reconcile's doc comment above). Best-
  /// effort and silent on failure: this must never disrupt normal hosting,
  /// and in ordinary operation (single real host, everyone else a plain
  /// client) no paired peer ever shows up here, since only the current host
  /// runs a server at all.
  Future<void> _reconcileGhostPairings(List<DiscoveredServer> others) async {
    if (_closing || !identity.isHost) return;
    final paired = identity.pairedDeviceIds;
    if (paired.isEmpty) return;
    for (final host in others) {
      if (host.deviceId == null || !paired.contains(host.deviceId)) continue;
      final pairings = <Map<String, String>>[
        for (final e in identity.pairedDeviceNames.entries)
          {'deviceId': e.key, 'deviceName': e.value},
      ];
      Map<String, dynamic>? revoked;
      try {
        revoked = await SignalingService.checkInWithHost(
          url: host.url,
          deviceId: identity.deviceId,
          deviceName: identity.deviceName,
          pairings: pairings,
        );
      } catch (e) {
        debugPrint('[host] ghost-pairing check-in with ${host.url} failed: $e');
        continue;
      }
      if (revoked == null || _closing) continue;
      final peer = PeerDevice.fromJson(Map<String, dynamic>.from(revoked));
      debugPrint('[host] ${host.url} confirmed ${peer.deviceId} is unpaired '
          '(ghost pairing) — dropping it locally');
      await identity.removePairedDevice(peer.deviceId);
      await _handlePeerGone(
        peer.deviceId,
        deviceName: peer.deviceName,
        explicit: true,
      );
    }
  }

  /// Called when the server connection drops. If I'm a client and the host
  /// stays unreachable for [_failoverDelay], I take over as host.
  void _onOffline() {
    _offlineSince ??= DateTime.now();
    if (identity.isHost || _closing) return;
    _failoverTimer ??= Timer(_failoverDelay, () {
      if (_closing || identity.isHost) return;
      if (connectionStatus != 'connected') {
        unawaited(_takeOverAsHost());
      }
    });
  }

  /// Called when the server connection (re)establishes.
  void _onConnected() {
    _offlineSince = null;
    _failoverTimer?.cancel();
    _failoverTimer = null;
    // Ensure the pairing list is fresh after (re)connect.
    signaling.getState();
  }

  Future<void> disposeAll() async {
    _closing = true;
    _failoverTimer?.cancel();
    _failoverTimer = null;
    _hostReconcileTimer?.cancel();
    _hostReconcileTimer = null;
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
          // Raw relayed chunk body; pair it with the oldest unmatched {t:'bin'}
          // marker (FIFO) so concurrent senders can't mis-route each other's
          // frames. Drop markers that have sat unmatched too long first — a
          // marker whose frame never arrived (sender died / server restarted)
          // must not steal the next peer's frame.
          final bytes = msg['bytes'];
          if (bytes is Uint8List) {
            _pruneStaleBinaryMarkers();
            if (_pendingRelayBinaryMarkers.isNotEmpty) {
              final marker = _pendingRelayBinaryMarkers.removeAt(0);
              _relayChannels[marker.from]?.handleRelayBinary(
                bytes,
                encrypted: marker.enc,
              );
            }
          }
          break;
        }
        connectionStatus =
            msg['event'] == 'connected' ? 'connected' : 'offline';
        if (msg['event'] == 'connected') {
          _onConnected();
        } else {
          _pendingRelayBinaryMarkers.clear();
          _onOffline();
        }
        notifyListeners();
        break;

      case 'registered':
        signaling.getState();
        break;

      case 'state':
        unawaited(_applyPairings(msg['pairings'] as List? ?? []));
        // Persist the paired-device list (with names) so a new host (after a
        // failover) can be told about the pairing on register.
        unawaited(identity.setPairedDevices(
          (msg['pairings'] as List? ?? []).whereType<Map>().map((m) =>
              MapEntry(
                m['deviceId'] as String? ?? '',
                m['deviceName'] as String? ?? '',
              )),
        ));
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
        await identity.addPairedDevice(peer.deviceId, name: peer.deviceName);
        _postMessage('Paired with ${peer.deviceName}');
        await _reconcileConnections();
        break;

      case 'unpaired':
        final peer = PeerDevice.fromJson(
          Map<String, dynamic>.from(msg['peer'] as Map),
        );
        await identity.removePairedDevice(peer.deviceId);
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
        debugPrint('[diag] relay from=$from t=${data['t']} hasChan=${_relayChannels.containsKey(from)} hasSyncChan=${sync.hasChannel(from)}');
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
            // Queue the marker; the frame handler pairs it with the oldest
            // unmatched marker (a FIFO) so concurrent senders can't mis-route
            // each other's frames. Timestamp it so a marker whose frame never
            // arrives can be pruned instead of stealing the next frame.
            _pendingRelayBinaryMarkers.add((
              from: from,
              enc: data['e'] == 1,
              at: DateTime.now(),
            ));
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
        if (!online) {
          // The peer went offline; any relayed-binary marker still waiting for
          // a frame from it is orphaned (its frame will never arrive).
          _pendingRelayBinaryMarkers.removeWhere((m) => m.from == peerId);
        }
        final idx =
            _pairedDevices.indexWhere((d) => d.deviceId == peerId);
        if (idx != -1) {
          _pairedDevices[idx] = _pairedDevices[idx].copyWith(online: online);
          notifyListeners();
        }
        await _reconcileConnections();
        break;

      case 'error':
        // While a smart pairing attempt is trying several servers, don't
        // snackbar each failure — pairSmart surfaces the final result.
        if (!_pairSmartActive) {
          _postMessage(msg['message'] as String? ?? 'Server error');
        }
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

  /// Test seam: process a server message through the same path as the live
  /// signaling stream (used to exercise binary relay routing deterministically).
  @visibleForTesting
  Future<void> handleServerMessage(Map<String, dynamic> msg) =>
      _onServerMessage(msg);

  /// Test seam: inject a relay channel for [peerId] so binary relay routing
  /// can be asserted without a live connection.
  @visibleForTesting
  void attachRelayChannelForTesting(String peerId, RelayDataChannel channel) {
    _relayChannels[peerId] = channel;
  }

  /// Drop any binary-relay marker that has been waiting for its frame for
  /// longer than [_markerMaxAge]. A marker and its frame travel back-to-back,
  /// so an old marker is orphaned (the sender died, its connection dropped, or
  /// the server restarted) and must not be paired with a later frame from a
  /// different peer.
  void _pruneStaleBinaryMarkers() {
    if (_pendingRelayBinaryMarkers.isEmpty) return;
    final cutoff = DateTime.now().subtract(_markerMaxAge);
    _pendingRelayBinaryMarkers.removeWhere((m) => m.at.isBefore(cutoff));
  }

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
    // Drop any relayed-binary markers still waiting for a frame from this peer
    // so they can't mis-route a future frame from another device.
    _pendingRelayBinaryMarkers.removeWhere((m) => m.from == deviceId);
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
      debugPrint('[diag] reconcile ${peer.deviceName} online=${peer.online} hasChannel=${sync.hasChannel(peer.deviceId)}');
      if (!peer.online) {
        sync.detachChannel(peer.deviceId);
        _relayChannels.remove(peer.deviceId);
        continue;
      }
      if (sync.hasChannel(peer.deviceId)) continue;
      debugPrint('[sync] attaching relay channel to ${peer.deviceName} (${peer.deviceId})');
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
    // each deletes the songs it received from the other. Also remove it
    // locally so the UI always responds, even if the server had lost the
    // pairing (a stale entry) and its unpair would otherwise have no-op'd.
    signaling.unpair(peer.deviceId);
    await identity.removePairedDevice(peer.deviceId);
    await _handlePeerGone(
      peer.deviceId,
      deviceName: peer.deviceName,
      explicit: true,
    );
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

  /// Searches YouTube using InnerTube.
  Future<List<YouTubeSearchResult>> searchYouTube(String query) {
    return YouTubeSearchService.search(query);
  }

  /// Downloads a YouTube search result via yt-dlp, adds to library, and returns
  /// the downloaded or existing Song for playback.
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

    // Check for freshly added song.
    final newSongs = library.songs.where((s) => !initialIds.contains(s.id));
    if (newSongs.isNotEmpty) {
      return (song: newSongs.first, error: null);
    }

    // Check for matching title in library if already present.
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
    await player.playSong(
      songs.first,
      queue: songs,
      sourceId: 'playlist:${playlist.id}',
      sourceTitle: playlist.name,
    );
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
    // Joining a REMOTE host means this device is not the host. Give up the
    // host role (stop the embedded server + clear isHost) right away instead
    // of waiting for the 30s reconcile — otherwise a code/QR join leaves two
    // devices hosting (and running servers) for a while, which shows up as
    // "weird" pairing behaviour. If the connect then fails, the normal 6s
    // failover re-hosts this device, so nothing is lost.
    final isRemote =
        !target.contains('localhost') && !target.contains('127.0.0.1');
    if (isRemote && identity.isHost) {
      _hostReconcileTimer?.cancel();
      _hostReconcileTimer = null;
      await identity.setIsHost(false);
      await server.stop();
    }
    if (identity.serverUrl != target) {
      await updateServerUrl(target);
    }
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (connectionStatus == 'connected') return true;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    if (connectionStatus != 'connected') _markUnreachable(target);
    return connectionStatus == 'connected';
  }

  /// Hosts we can currently try to connect to — drops URLs we recently failed
  /// to reach so host election can't loop against a dead or wrong address.
  List<DiscoveredServer> _filterReachable(List<DiscoveredServer> hosts) {
    if (hosts.isEmpty) return hosts;
    final now = DateTime.now();
    _unreachableHosts
        .removeWhere((_, t) => now.difference(t) > _unreachableCooldown);
    if (_unreachableHosts.isEmpty) return hosts;
    return hosts.where((h) => !_unreachableHosts.containsKey(h.url)).toList();
  }

  void _markUnreachable(String url) {
    _unreachableHosts[url] = DateTime.now();
  }

  /// LocalSend-style LAN discovery: finds nearby Pear Music servers on the
  /// same network. Excludes this device itself. Background callers use passive
  /// multicast only ([allowSubnetScan] = false).
  Future<List<DiscoveredServer>> discoverNearby({
    bool allowSubnetScan = false,
  }) async {
    try {
      final found = await ServerDiscovery.discover(
        allowSubnetScan: allowSubnetScan,
      );
      return found
          .where((d) => d.deviceId != null && d.deviceId != identity.deviceId)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Smart pairing for MANUAL code entry (LocalSend-style): tries the code on
  /// the current server, then discovers nearby devices and retries the code on
  /// each, so typing the code works even when this device is on a different
  /// server than the host. Returns an error message on failure, null on success.
  Future<String?> pairSmart(String code) async {
    final c = code.trim().toUpperCase();
    if (c.length != 6) return 'Enter the 6-character code';

    _pairSmartActive = true;
    try {
      // 1) Try on the current server first (fast path when already aligned).
      if (connectionStatus == 'connected') {
        signaling.pairWithCode(c);
        if (await _waitForPairingOutcome(const Duration(seconds: 4))) return null;
      }

      // 2) Discover nearby hosts (actively probing subnet fallback if multicast misses).
      final hosts = await discoverNearby(allowSubnetScan: true);
      for (final host in hosts) {
        if (host.url == identity.serverUrl) continue;
        if (!await connectToServer(host.url)) continue;
        signaling.pairWithCode(c);
        if (await _waitForPairingOutcome(const Duration(seconds: 4))) return null;
      }

      return 'No device found with that code. Make sure the other device has '
          'the Pair screen open, or scan its QR code.';
    } finally {
      _pairSmartActive = false;
    }
  }

  /// Waits up to [timeout] for the server to confirm (paired) or reject
  /// (error) the current pairing attempt. True = paired.
  Future<bool> _waitForPairingOutcome(Duration timeout) async {
    final completer = Completer<bool>();
    late final StreamSubscription<Map<String, dynamic>> sub;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    sub = signaling.stream.listen((msg) {
      if (msg['type'] == 'paired') {
        if (!completer.isCompleted) completer.complete(true);
      } else if (msg['type'] == 'error') {
        if (!completer.isCompleted) completer.complete(false);
      }
    });
    final result = await completer.future;
    timer.cancel();
    await sub.cancel();
    return result;
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
