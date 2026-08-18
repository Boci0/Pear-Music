# Fix Plan Part 2: Ghost Pairing Can Persist Forever (Host Election Gap)

**This is an ADDENDUM to `GHOST_PAIRING_FIX_PLAN.md`, not a replacement.**
That plan's tombstone mechanism is correct and does not need to change — it
was just never being *invoked* in the case you hit. This plan adds the
missing trigger.

**Files you will edit:**
- `app/lib/services/signaling_service.dart` (1 addition — a new static method)
- `app/lib/controllers/app_controller.dart` (1 addition — a new function,
  wired into an existing timer)
- `app/test/pairing_checkin_test.dart` (new file — regression test)

**Precondition: Part 1's tombstone fix must already be applied** to
`signaling_server.dart`. This plan calls the server behavior Part 1 added;
without it, the server has nothing to report back.

---

## Root cause: host election, not the tombstone logic, was the gap

Part 1's fix lives entirely in `_onRegister` on the server: when a device
*registers* and self-reports a pairing that's tombstoned, the server refuses
to restore it and pushes an `unpaired` correction. That part works — verified
by the tests in Part 1's plan.

The gap: **that logic only runs when a device registers with the OTHER
device's server.** Whether that ever happens is decided entirely by host
election, in `app_controller.dart`:

```dart
Future<void> _reconcileHost() async {
  if (_closing || !identity.isHost) return;
  final others = _filterReachable(await discoverNearby());
  for (final host in others) {
    final otherId = host.deviceId;
    if (otherId != null && otherId.compareTo(identity.deviceId) < 0) {
      // only defer if the OTHER host's id sorts BEFORE ours
      ...
      await updateServerUrl(host.url);   // <- THIS is what triggers register
      return;
    }
  }
}
```

This runs every 30 seconds while a device believes it's the host. It only
makes a device defer (and thus connect + register, which is the only thing
that triggers Part 1's fix) if the *other* discovered host's `deviceId`
string sorts before its own. If Device 1 (the ghosting device)'s id happens
to sort **before** Device 2's, Device 1 will run this check forever, always
conclude "I win," and **never once connect to Device 2's server** — meaning
Part 1's tombstone check never gets a chance to run, no matter how long both
devices stay online together on the same network. That matches exactly what
you saw: it doesn't unpair "for a while" because there's no time limit on
it — it's not slow, it's simply never going to happen on its own.

## The fix

Give a self-hosting device a way to check pairing state with a paired peer
that's independently hosting, **without** needing to win or lose the host
election — a short, throwaway connection made purely to ask "are we still
actually paired?", separate from the main connection that handles hosting.

### Edit 1 — `app/lib/services/signaling_service.dart`: add `checkInWithHost`

Add this as a new method on the `SignalingService` class (e.g. right after
the existing `getState()` method, before `dispose()`):

```dart
  /// One-shot "pairing check-in" with [url], independent of this instance's
  /// main connection. Registers reporting [pairings] (our own believed
  /// pairing list) and returns the peer map from an `unpaired` push if that
  /// server says this device's pairing to one of them is dead (tombstoned);
  /// returns null on success/no correction/any failure. Always closes the
  /// socket before returning — this never leaves a lingering connection.
  ///
  /// Needed because normal pairing reconciliation only runs when a device
  /// REGISTERS with a host. If two paired devices both end up independently
  /// hosting their own server (a "split brain" — e.g. after a failover where
  /// host-election never makes either defer to the other), neither's
  /// register-time reconciliation ever runs against the other, so a pairing
  /// broken on one side can appear to "stick forever" on the other. This
  /// lets a host proactively check in with such a peer without disturbing
  /// its own hosting role or its main connection.
  static Future<Map<String, dynamic>?> checkInWithHost({
    required String url,
    required String deviceId,
    required String deviceName,
    required List<Map<String, String>> pairings,
    Duration timeout = const Duration(seconds: 5),
    Duration graceAfterRegistered = const Duration(milliseconds: 400),
  }) async {
    WebSocketChannel? channel;
    StreamSubscription<dynamic>? sub;
    Timer? graceTimer;
    try {
      channel = WebSocketChannel.connect(Uri.parse(url));
      await channel.ready.timeout(timeout);
      final completer = Completer<Map<String, dynamic>?>();
      sub = channel.stream.listen((raw) {
        if (raw is! String || completer.isCompleted) return;
        Map<String, dynamic> msg;
        try {
          msg = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        if (msg['type'] == 'unpaired') {
          completer.complete(Map<String, dynamic>.from(msg['peer'] as Map));
        } else if (msg['type'] == 'registered') {
          // The server sends any correction ('unpaired') right after
          // 'registered', synchronously, in the same register handler — so a
          // short grace window is enough to know "no correction is coming"
          // without blocking the full [timeout] on every ordinary check-in.
          graceTimer ??= Timer(graceAfterRegistered, () {
            if (!completer.isCompleted) completer.complete(null);
          });
        }
      }, onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      }, onDone: () {
        if (!completer.isCompleted) completer.complete(null);
      });
      channel.sink.add(jsonEncode({
        'type': 'register',
        'deviceId': deviceId,
        'deviceName': deviceName,
        'secret': '',
        'pairings': pairings,
      }));
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      graceTimer?.cancel();
      await sub?.cancel();
      try {
        await channel?.sink.close();
      } catch (_) {}
    }
  }
```

No new imports needed — `dart:async` (`Completer`, `Timer`,
`StreamSubscription`), `dart:convert` (`jsonEncode`/`jsonDecode`), and
`web_socket_channel` are already imported at the top of this file.

**Why `secret: ''`:** in the scenario this fixes, the checking-in device has
never registered with the target server before (it's a stranger to that
server), so there's no existing secret to present, and the server just binds
a fresh one for this throwaway session — see `_onRegister`'s `else` branch
in `signaling_server.dart`, which already handles "no existing secret"
gracefully for any first-time device id. If the two servers *have* talked
before and a secret mismatch causes a rejection, this check-in just fails
silently and retries next cycle (see "Safety" below) — no data loss, just a
skipped reconciliation pass.

### Edit 2 — `app/lib/controllers/app_controller.dart`: run it periodically

**FIND THIS** (exact text, appears once):

```dart
  /// One-shot check shortly after becoming host: if a higher-priority host
  /// (smaller deviceId) is also online — e.g. two devices started at once —
  /// defer to it so there is always exactly one host. Also re-checks every 30s
  /// while hosting, so this device hands back to the original host as soon as
  /// it returns (host switching recovers fast in BOTH directions).
  void _scheduleHostReconcile() {
    _hostReconcileTimer?.cancel();
    Timer(const Duration(seconds: 3), () => unawaited(_reconcileHost()));
    _hostReconcileTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => unawaited(_reconcileHost()));
  }

  Future<void> _reconcileHost() async {
    if (_closing || !identity.isHost) return;
    final others = _filterReachable(await discoverNearby());
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
```

**REPLACE WITH:**

```dart
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
    Timer(const Duration(seconds: 3), () {
      unawaited(_reconcileHost());
      unawaited(_reconcileGhostPairings());
    });
    _hostReconcileTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_reconcileHost());
      unawaited(_reconcileGhostPairings());
    });
  }

  Future<void> _reconcileHost() async {
    if (_closing || !identity.isHost) return;
    final others = _filterReachable(await discoverNearby());
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
  Future<void> _reconcileGhostPairings() async {
    if (_closing || !identity.isHost) return;
    final paired = identity.pairedDeviceIds;
    if (paired.isEmpty) return;
    final others = _filterReachable(await discoverNearby());
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
```

No new imports needed in this file either — `PeerDevice`, `SignalingService`,
`identity`, `discoverNearby`, `_filterReachable`, and `_handlePeerGone` are
all already used elsewhere in the same file.

---

## Why this is precise — what it does and doesn't touch

- **Only fires in the split-brain condition itself.** The loop only acts on
  a discovered host whose `deviceId` is already in `identity.pairedDeviceIds`.
  In ordinary, correctly-converged operation there is exactly one real host;
  every other paired device is a plain client and doesn't run a server, so
  it can never appear in `discoverNearby()`'s results. This function is a
  no-op on every tick except during an actual split-brain.
- **Can only ever remove a pairing, never add one.** `checkInWithHost` only
  acts on an explicit `unpaired` push, which (per Part 1) the server only
  ever sends for a pairing it has a persisted tombstone for. There's no path
  by which this makes up a correction that isn't already backed by the
  other server's own record of an explicit unpair.
- **Doesn't touch host election, hosting, or the main connection.** It
  doesn't call `updateServerUrl`, doesn't stop the local server, doesn't
  change `identity.isHost`. A device keeps hosting exactly as it did before;
  this just also asks a question of a peer's server on the side.
- **Fails silently and safely.** Any error (unreachable host, timeout, auth
  rejection because a stale secret from a past session doesn't match) is
  caught and simply skipped — the loop tries the next discovered host if
  any, and the whole thing retries again on the next 30s tick regardless.
  Nothing here can throw into the timer callback or crash the app.
- **Cheap in the common (no-op) case.** The `graceAfterRegistered` window
  (400ms) means a check-in against a peer that turns out to still be validly
  paired resolves in well under half a second, not the full 5s timeout —
  confirmed by the "genuinely still valid" regression test below.

---

## Regression test — new file `app/test/pairing_checkin_test.dart`

This tests the deterministic, unit-testable core (`checkInWithHost` against
a real `SignalingServer`). The other half — `discoverNearby()` actually
finding a peer via real LAN multicast — isn't something a fast, deterministic
unit test can exercise; see the manual repro at the end instead.

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:peerm_app/services/signaling_server.dart';
import 'package:peerm_app/services/signaling_service.dart';

/// Minimal WebSocket test client. Duplicated from signaling_server_test.dart
/// (which keeps its own copy private to that file) so this file stays
/// self-contained.
class _Client {
  _Client(this.ws) {
    _sub = ws.listen((data) => _messages.add(data), onError: (_) {});
  }
  final WebSocket ws;
  final List<dynamic> _messages = [];
  StreamSubscription<dynamic>? _sub;

  Future<Map<String, dynamic>> next(String type) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      for (var i = 0; i < _messages.length; i++) {
        final m = _messages[i];
        if (m is String) {
          try {
            final d = jsonDecode(m);
            if (d is Map && d['type'] == type) {
              _messages.removeAt(i);
              return d.cast<String, dynamic>();
            }
          } catch (_) {}
        }
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting for "$type" (have ${_messages.length} messages)');
  }

  void sendText(Map<String, dynamic> msg) => ws.add(jsonEncode(msg));

  Future<void> close() async {
    try {
      await _sub?.cancel();
      await ws.close();
    } catch (_) {}
  }
}

Future<_Client> _connect(int port) async {
  final ws = await WebSocket.connect('ws://127.0.0.1:$port');
  return _Client(ws);
}

void main() {
  test(
      'checkInWithHost surfaces a tombstoned pairing without disturbing the '
      "server's normal state", () async {
    final server = SignalingServer(port: 0, host: '127.0.0.1');
    await server.start();
    try {
      // Seed the exact split-brain precondition: A and B pair, then B
      // explicitly unpairs A while A is not connected (A never learns).
      final b = await _connect(server.boundPort);
      b.sendText({'type': 'register', 'deviceId': 'B', 'deviceName': 'Dev B'});
      await b.next('registered');

      final a1 = await _connect(server.boundPort);
      a1.sendText({'type': 'register', 'deviceId': 'A', 'deviceName': 'Dev A'});
      await a1.next('registered');

      a1.sendText({'type': 'create_pairing'});
      final code = (await a1.next('pairing_created'))['code'] as String;
      b.sendText({'type': 'pair_with_code', 'code': code});
      await b.next('paired');
      await a1.next('paired');

      b.sendText({'type': 'unpair', 'peerId': 'A'});
      await b.next('unpaired');
      await a1.close();

      // A comes back as its own independent host and never re-registers
      // with this server directly — instead it does exactly what
      // AppController._reconcileGhostPairings does: a one-shot check-in.
      final revoked = await SignalingService.checkInWithHost(
        url: 'ws://127.0.0.1:${server.boundPort}',
        deviceId: 'A',
        deviceName: 'Dev A',
        pairings: const [
          {'deviceId': 'B', 'deviceName': 'Dev B'},
        ],
      );

      expect(revoked, isNotNull,
          reason: 'the server must report the tombstoned pairing back');
      expect(revoked!['deviceId'], 'B');

      // A second check-in must be harmless (no crash, no resurrection) —
      // confirms it's safe to run on every 30s reconcile tick.
      final again = await SignalingService.checkInWithHost(
        url: 'ws://127.0.0.1:${server.boundPort}',
        deviceId: 'A',
        deviceName: 'Dev A',
        pairings: const [
          {'deviceId': 'B', 'deviceName': 'Dev B'},
        ],
      );
      expect(again, isNotNull);
      expect(again!['deviceId'], 'B');

      await b.close();
    } finally {
      await server.stop();
    }
  });

  test('checkInWithHost does not revoke a pairing that is genuinely still '
      'valid', () async {
    final server = SignalingServer(port: 0, host: '127.0.0.1');
    await server.start();
    try {
      final b = await _connect(server.boundPort);
      b.sendText({'type': 'register', 'deviceId': 'B', 'deviceName': 'Dev B'});
      await b.next('registered');
      final a = await _connect(server.boundPort);
      a.sendText({'type': 'register', 'deviceId': 'A', 'deviceName': 'Dev A'});
      await a.next('registered');
      a.sendText({'type': 'create_pairing'});
      final code = (await a.next('pairing_created'))['code'] as String;
      b.sendText({'type': 'pair_with_code', 'code': code});
      await b.next('paired');
      await a.next('paired');
      await a.close(); // A goes offline, but was never unpaired.

      final revoked = await SignalingService.checkInWithHost(
        url: 'ws://127.0.0.1:${server.boundPort}',
        deviceId: 'A',
        deviceName: 'Dev A',
        pairings: const [
          {'deviceId': 'B', 'deviceName': 'Dev B'},
        ],
      );
      expect(revoked, isNull,
          reason: 'a real, still-valid pairing must never be revoked');

      await b.close();
    } finally {
      await server.stop();
    }
  });

  test('checkInWithHost returns null against an unreachable server', () async {
    final revoked = await SignalingService.checkInWithHost(
      url: 'ws://127.0.0.1:1', // nothing listens here
      deviceId: 'A',
      deviceName: 'Dev A',
      pairings: const [],
      timeout: const Duration(seconds: 1),
    );
    expect(revoked, isNull);
  });
}
```

Run: `cd app && flutter test test/pairing_checkin_test.dart` — all three
tests must pass. The second test should complete in well under a second
(proves the grace-window optimization works, not just the timeout path).

## Full verification

```bash
cd app
flutter analyze
flutter test
```

Then the manual repro from Part 1's plan (section 5.4), but this time **wait
through at least one 30–33 second window** with both devices on the same
network before checking — that's the new mechanism's cadence (a 3s initial
check plus a 30s periodic timer). If it's still wrong after ~35 seconds with
both devices genuinely reachable on the same LAN, the gap is elsewhere (most
likely LAN discovery itself not finding the peer — check that both devices
show up in each other's "nearby devices" / discovery list at all before
suspecting this fix).