# Fix Plan: "Ghost Pairing" Bug in Pear-Music

**Repo:** https://github.com/Boci0/Pear-Music.git
**File you will edit:** `app/lib/services/signaling_server.dart`
**Nothing else needs to change.** One file, seven small edits.

> **How to use this document if you are an AI coding agent:**
> Do not skip ahead. Do not "improve" or reorganize anything beyond what is
> asked. Each numbered edit below gives you:
> 1. The exact file path.
> 2. A block of text labeled `FIND THIS` — search for it verbatim. It occurs
>    exactly once in the file.
> 3. A block of text labeled `REPLACE WITH` — replace the `FIND THIS` block
>    with this text, exactly.
> 4. A one-paragraph explanation of *why*, which you may read but do not need
>    to reason about further — the "what to type" is already fully decided.
>
> Apply the edits **in order, 1 through 7**. After each edit, re-read the
> surrounding ~10 lines to confirm the file still looks like normal Dart code
> (matching braces, no duplicated lines). Do not run a formatter or reformat
> unrelated code. When all 7 edits are applied, go to the **Verification**
> section at the end and follow it exactly.

---

## 1. The bug, in plain terms

This is what the user reported, reproduced exactly:

```
Device 1: Host
Device 2: Pair
Device 1,2: Share files until completed
Device 1: terminated
Device 2: New host
Device 2: Unpair device 1
Device 1: reopen
Device 1: Kept all songs from device 2 and still paired to device 2
Device 2: shows no paired
```

In other words: Device 2 correctly unpairs Device 1. But when Device 1 comes
back, it still believes it is paired to Device 2, and it never lost the songs
it received from Device 2. Device 2, meanwhile, correctly shows "not paired."
The two devices disagree about reality forever. This is the "ghost pairing."

---

## 2. Root cause (you do not need to re-derive this — it is already found)

### 2.1 Background fact about this app's architecture

Every device — phone, PC, whichever — can run its own **embedded signaling
server** (`app/lib/services/signaling_server.dart`). At any moment, exactly
one device on the network is "the host" and runs this server; every other
device is a client connected to it. Each device's server keeps its own
**separate, local, on-disk state file**
(`peerm_server_state.json` under that device's own app-support directory —
see `app/lib/main.dart` around line 78). These state files are **not shared**
between devices. There is no cloud, no central database — the source code
comment in the repo literally says "No cloud, no accounts."

This matters because: **Device 1's server and Device 2's server are two
totally separate programs with two totally separate files on disk.** Nothing
one of them writes is automatically known by the other, except through live
WebSocket messages sent while both happen to be connected to the same server
at the same time.

### 2.2 What actually happens, step by step

1. Device 1 is host. It runs `signaling_server.dart`, with its own state
   file, call it `state-1.json`. Device 2 connects to Device 1 as a client
   and pairs. `state-1.json` now contains the pairing `(Device1, Device2)`.
   Device 2 also locally caches "I am paired with Device 1" in its own local
   app storage (`app/lib/services/identity_service.dart`, the `_paired` map,
   persisted under the key `peerm_paired_device_ids`).

2. Device 1 is terminated (app killed). `state-1.json` still says
   `(Device1, Device2)` are paired — nobody told it otherwise, because Device
   1's process is dead and can't receive any message.

3. Device 2 loses its host (Device 1 is gone) and takes over as the new
   host. It starts **its own** server, with **its own** state file, call it
   `state-2.json`. This file starts out learning the pairing from Device 2's
   own local client cache (a documented, intentional feature — see the
   "Restore pairings this device reports" comment in `_onRegister`). So
   `state-2.json` also ends up containing `(Device1, Device2)` — for now.

4. Device 2 unpairs Device 1. This sends an `unpair` message to Device 2's
   OWN server (`state-2.json`), which removes the pairing there and updates
   Device 2's own local client cache too. **`state-1.json` — which lives on
   Device 1's disk, and which nobody can currently reach because Device 1 is
   powered off — is completely untouched.** There is no way for the unpair
   action to reach a file on a powered-off device. This part is an
   unavoidable fact of a fully decentralized app with no server in the cloud,
   and is not itself the bug to fix — but it is the reason the "ghost" is
   even possible.

5. Device 1 reopens. On startup it checks: "was I the host last time?" Yes
   (it never got the chance to record otherwise). It looks for another
   already-running host on the network (`discoverNearby()` in
   `app/lib/controllers/app_controller.dart`). **If, for any reason — timing,
   network, a firewall, being on a different Wi-Fi — that discovery does not
   find Device 2 in time,** Device 1 just starts hosting itself again, using
   its own **stale, never-updated** `state-1.json`, which still says it is
   paired with Device 2. This is why Device 1 shows "paired" and keeps the
   songs: as far as Device 1's own private, offline record is concerned,
   nothing ever changed.

### 2.3 The actual code bug (this is the part we are fixing)

The app's authors already anticipated part of this problem. There is an
existing safety mechanism, described in a comment in
`app/lib/services/signaling_server.dart` around line 66-82, called
**"reconcile-on-register."** The idea: whenever a device connects to a
server and registers, it reports its own list of who it thinks it's paired
with. The server is supposed to treat that report as authoritative — if the
device *used to* be paired with someone but no longer reports them, the
server prunes that pairing, so an unpair "sticks."

**The bug:** look at the function `_onRegister` in
`app/lib/services/signaling_server.dart` (around line 561 onward, in the
*original, unmodified* file). When a device registers and reports a
pairing list, the server code does this, *in this exact order*:

1. For every peer the connecting device reports, it **immediately adds that
   pairing to its own persisted, authoritative state** (`_persistedPairs`),
   *no questions asked.*
2. *Only after that*, it runs the "reconcile" step that removes pairings the
   device *didn't* report.

Because step 1 always adds whatever the device claims, and step 2 only
removes what's *missing* from the claim, **a device can never lose a
pairing it insists on reporting** — even if that pairing was explicitly,
deliberately broken by the other party while this device was offline. There
is currently **no persisted record anywhere that a pairing was intentionally
undone.** The server only remembers the *current* set of pairings; it never
remembers "and this specific pair was explicitly killed on purpose, so don't
trust anyone who claims otherwise." That missing memory is the actual bug.

**The fix:** give the server a persisted memory of explicit unpairs — an
"unpair tombstone" — and check it before ever trusting a reconnecting
device's self-reported pairing list.

---

## 3. The fix, at a glance

Add to `app/lib/services/signaling_server.dart`:

1. A new in-memory + persisted-to-disk map, `_pairTombstones`, recording
   *when* each pair was explicitly unpaired.
2. Whenever an explicit unpair happens (`_removePair`), record a tombstone
   for that pair.
3. Whenever a fresh, deliberate re-pair happens (`_addPair`), clear any old
   tombstone for that pair (so two devices CAN re-pair after unpairing once).
4. In `_onRegister`, before adding a peer the connecting device self-reports,
   check the tombstone. If that exact pair is tombstoned: **do not** add it
   back, and instead send the connecting device an explicit `unpaired`
   message right away so its local cache and UI correct themselves
   immediately (instead of silently staying wrong).
5. Persist tombstones to the state file (`_saveState` / `_loadState`) so they
   survive server restarts.
6. Expire old tombstones after 30 days during the server's existing periodic
   cleanup pass (`_gcStalePairings`), so the map doesn't grow forever.

This does **not** fix step 5 in section 2.2 above (Device 1 self-hosting from
a stale file with zero communication to Device 2 — that's physically
impossible to fix without a network round-trip that never happens). What it
DOES fix: **the moment Device 1 and Device 2 actually reconnect to each
other** (Device 1 discovers Device 2's host and connects as a client, or
vice versa — which the app already tries to do periodically on its own),
the ghost pairing self-heals immediately instead of resurrecting or staying
wrong forever. That is the correct, complete fix given the constraints of a
fully offline, cloud-free app.

---

## 4. Step-by-step edits

All edits are in **one file**: `app/lib/services/signaling_server.dart`.

### Edit 1 of 7 — declare the new `tombstoneTtl` constant and document mechanism #4

**FIND THIS** (exact text, appears once):

```dart
  //   3. [staleAfter] GC: a persisted pairing where BOTH devices have been
  //      un-seen for this long is removed from the state file entirely.
  static const Duration offlineReportGrace = Duration(days: 7);
  static const Duration staleAfter = Duration(days: 30);
  static const Duration gcPeriod = Duration(hours: 6);
```

**REPLACE WITH:**

```dart
  //   3. [staleAfter] GC: a persisted pairing where BOTH devices have been
  //      un-seen for this long is removed from the state file entirely.
  //   4. Unpair tombstones: mechanism #2 assumes the reporting device's list
  //      is trustworthy, but a device that was OFFLINE at the moment its peer
  //      unpaired it never learns that and keeps reporting the dead pairing
  //      forever — which used to make register()  silently RE-ADD it (the
  //      classic "ghost pairing": device A unpairs device B while B is
  //      offline, B is reachable again and reconnects/re-hosts, and the old
  //      pairing comes back on A's side too, or B is stuck forever showing
  //      "paired" to a peer that has no record of it at all). Every explicit
  //      unpair now leaves a persisted tombstone for [tombstoneTtl]; register()
  //      refuses to restore a tombstoned pair from a client's self-reported
  //      list and instead tells the client to drop it, so an unpair sticks
  //      even across the unpaired device's own restarts.
  static const Duration offlineReportGrace = Duration(days: 7);
  static const Duration staleAfter = Duration(days: 30);
  static const Duration tombstoneTtl = Duration(days: 30);
  static const Duration gcPeriod = Duration(hours: 6);
```

*Why:* declares how long a tombstone is remembered (30 days — same window
the app already uses elsewhere for "this pairing is truly dead" cleanup), and
documents the new mechanism next to the three that already exist, matching
the file's existing documentation style.

---

### Edit 2 of 7 — add the tombstone storage map and helper functions

**FIND THIS** (exact text, appears once):

```dart
  final Map<String, String> _persistedNames = {};
  final Map<String, String> _persistedSecrets = {};
  final Map<String, DateTime> _persistedLastSeen = {};
  Timer? _gcTimer;

  final Random _rng = Random.secure();
```

**REPLACE WITH:**

```dart
  final Map<String, String> _persistedNames = {};
  final Map<String, String> _persistedSecrets = {};
  final Map<String, DateTime> _persistedLastSeen = {};
  // Explicit-unpair tombstones, keyed by the pair (order-independent). See
  // "Ghost-pair cleanup" mechanism #4 above.
  final Map<String, DateTime> _pairTombstones = {};
  Timer? _gcTimer;

  static String _pairKey(String aId, String bId) =>
      aId.compareTo(bId) < 0 ? '$aId|$bId' : '$bId|$aId';

  void _tombstonePair(String aId, String bId) {
    _pairTombstones[_pairKey(aId, bId)] = DateTime.now();
  }

  bool _isTombstoned(String aId, String bId) =>
      _pairTombstones.containsKey(_pairKey(aId, bId));

  void _clearTombstone(String aId, String bId) {
    _pairTombstones.remove(_pairKey(aId, bId));
  }

  final Random _rng = Random.secure();
```

*Why:* `_pairTombstones` is the new memory of "this pair was explicitly
unpaired, and when." The key is built the same order-independent way the
file already builds pairing keys elsewhere (see `_saveState`, which does
`aId.compareTo(bId) < 0 ? '$aId|$bId' : '$bId|$aId'` — we're reusing that
exact pattern as a named helper).

---

### Edit 3 of 7 — check the tombstone before restoring a self-reported pairing, in `_onRegister`

**FIND THIS** (exact text, appears once):

```dart
    // Restore pairings this device reports — used after a HOST FAILOVER: the
    // new host learns the existing pairing from the connecting client instead
    // of starting empty (which would unpair them and wipe shared songs).
    final restored = msg['pairings'];
    final reportedIds = <String>{};
    var restoredAny = false;
    if (restored is List) {
      for (final item in restored) {
        String? pid;
        String? pname;
        if (item is String) {
          pid = item;
        } else if (item is Map) {
          pid = item['deviceId'] as String?;
          pname = item['deviceName'] as String?;
        }
        if (pid == null || pid.isEmpty || pid == id) continue;
        reportedIds.add(pid);
        if (conn.pairings.add(pid)) {
          _persistedPairs.putIfAbsent(id, () => <String>{}).add(pid);
          _persistedPairs.putIfAbsent(pid, () => <String>{}).add(id);
          restoredAny = true;
        }
        if (pname != null && pname.isNotEmpty) {
          _persistedNames[pid] = pname;
        }
      }
    }
    _devices[id] = conn;
```

**REPLACE WITH:**

```dart
    // Restore pairings this device reports — used after a HOST FAILOVER: the
    // new host learns the existing pairing from the connecting client instead
    // of starting empty (which would unpair them and wipe shared songs).
    final restored = msg['pairings'];
    final reportedIds = <String>{};
    // Peers this device still thinks it's paired with, but that were
    // EXPLICITLY unpaired (by the other side, or by a previous host) while
    // this device was offline. We must not let its stale self-report
    // resurrect them — instead we tell it to drop them below.
    final revokedPeers = <Map<String, String>>[];
    var restoredAny = false;
    if (restored is List) {
      for (final item in restored) {
        String? pid;
        String? pname;
        if (item is String) {
          pid = item;
        } else if (item is Map) {
          pid = item['deviceId'] as String?;
          pname = item['deviceName'] as String?;
        }
        if (pid == null || pid.isEmpty || pid == id) continue;
        if (_isTombstoned(id, pid)) {
          conn.pairings.remove(pid);
          _removePersistedPair(id, pid);
          revokedPeers.add({
            'deviceId': pid,
            'deviceName': pname ?? _persistedNames[pid] ?? 'Unnamed device',
          });
          continue; // do NOT add to reportedIds — a tombstoned pair must not
          // survive the reconcile step below either.
        }
        reportedIds.add(pid);
        if (conn.pairings.add(pid)) {
          _persistedPairs.putIfAbsent(id, () => <String>{}).add(pid);
          _persistedPairs.putIfAbsent(pid, () => <String>{}).add(id);
          restoredAny = true;
        }
        if (pname != null && pname.isNotEmpty) {
          _persistedNames[pid] = pname;
        }
      }
    }
    _devices[id] = conn;
```

*Why:* this is the actual bug fix. Before, every self-reported peer was
trusted and re-added unconditionally. Now, each self-reported peer is first
checked against the tombstone map. If it's tombstoned, we actively remove it
from this connection's live pairing set and from persisted storage (in case
it lingered), and we remember it in `revokedPeers` so we can tell the client
about it (next edit). Critically, a tombstoned peer is **not** added to
`reportedIds`, so the pre-existing reconcile step further down (which prunes
anything not in `reportedIds`) also can't be tricked into keeping it.

---

### Edit 4 of 7 — actively tell the reconnecting device to drop any tombstoned peer

**FIND THIS** (exact text, appears once):

```dart
    conn.send({
      'type': 'registered',
      'deviceId': id,
      'secret': _persistedSecrets[id],
    });
    _sendState(conn);
    _notifyPresence(id);
    _log('[register] $name ($id)');
  }
```

**REPLACE WITH:**

```dart
    conn.send({
      'type': 'registered',
      'deviceId': id,
      'secret': _persistedSecrets[id],
    });
    // Explicitly correct any ghost pairings before sending state, so the
    // client's local paired-device cache (and shared songs from that peer)
    // are cleared immediately instead of silently dropping out of `state`.
    for (final peer in revokedPeers) {
      conn.send({'type': 'unpaired', 'peer': peer});
      _log('[unpair] told ${conn.name} to drop stale pairing '
          '${peer['deviceName']} (${peer['deviceId']}) — tombstoned');
    }
    _sendState(conn);
    _notifyPresence(id);
    _log('[register] $name ($id)');
  }
```

*Why:* the client app already has correct, existing handling for an
`unpaired` message (see `app/lib/controllers/app_controller.dart`, the
`case 'unpaired':` branch — it calls `identity.removePairedDevice(...)` and
removes that peer's songs). By sending this message right after register, we
reuse that existing, already-correct client logic instead of writing new
client-side code. This is the message that makes Device 1's UI and song
library actually update, instead of just quietly not-resurrecting the
pairing on the server.

---

### Edit 5 of 7 — clear the tombstone on a fresh, deliberate re-pair

**FIND THIS** (exact text, appears once):

```dart
  void _addPair(String aId, String bId) {
    _pairingsOf(aId).add(bId);
    _pairingsOf(bId).add(aId);
    _addPersistedPair(aId, bId);
    _saveState();
  }
```

**REPLACE WITH:**

```dart
  void _addPair(String aId, String bId) {
    _pairingsOf(aId).add(bId);
    _pairingsOf(bId).add(aId);
    _addPersistedPair(aId, bId);
    // A fresh, deliberate re-pair always wins over a stale tombstone from a
    // previous unpair — otherwise two devices could never re-pair after
    // unpairing once.
    _clearTombstone(aId, bId);
    _saveState();
  }
```

*Why:* without this, two devices that unpair and then later deliberately
re-pair (using a brand-new pairing code, an explicit user action) would keep
getting silently blocked by the leftover tombstone from the first unpair.
This makes sure a genuine new pairing always overrides old history.

---

### Edit 6 of 7 — record a tombstone whenever a pair is explicitly broken

**FIND THIS** (exact text, appears once):

```dart
  void _removePair(String aId, String bId) {
    _pairingsOf(aId).remove(bId);
    _pairingsOf(bId).remove(aId);
    _removePersistedPair(aId, bId);
    _saveState();
  }
```

**REPLACE WITH:**

```dart
  void _removePair(String aId, String bId) {
    _pairingsOf(aId).remove(bId);
    _pairingsOf(bId).remove(aId);
    _removePersistedPair(aId, bId);
    // Record that this pair was EXPLICITLY broken, so a device that was
    // offline at the time (and still reports the old pairing when it comes
    // back) can't silently resurrect it — see mechanism #4 above.
    _tombstonePair(aId, bId);
    _saveState();
  }
```

*Why:* `_removePair` is only ever called from the `case 'unpair':` message
handler — i.e., it only runs when a user deliberately unpairs a device
(never from routine cleanup code). That makes it exactly the right, and
only, place to create a tombstone.

---

### Edit 7 of 7 — persist tombstones to disk, load them back, and expire old ones

This edit has **three separate small changes** within the same function
area. Apply all three.

#### 7a. Expire old tombstones during the existing periodic cleanup

**FIND THIS** (exact text, appears once):

```dart
    if (stalePairs.isEmpty) return;
    for (final (a, b) in stalePairs) {
      _removePersistedPair(a, b);
    }
    _saveState();
    _log('[persist] cleaned ${stalePairs.length} stale pairing(s)');
  }
```

**REPLACE WITH:**

```dart
    final expiredTombstones = <String>[];
    _pairTombstones.forEach((key, at) {
      if (now.difference(at) > tombstoneTtl) expiredTombstones.add(key);
    });
    for (final key in expiredTombstones) {
      _pairTombstones.remove(key);
    }

    if (stalePairs.isEmpty && expiredTombstones.isEmpty) return;
    for (final (a, b) in stalePairs) {
      _removePersistedPair(a, b);
    }
    _saveState();
    if (stalePairs.isNotEmpty) {
      _log('[persist] cleaned ${stalePairs.length} stale pairing(s)');
    }
    if (expiredTombstones.isNotEmpty) {
      _log('[persist] expired ${expiredTombstones.length} unpair tombstone(s)');
    }
  }
```

> Note: this code block lives inside the existing `_gcStalePairings()`
> function, which already has a local variable named `now` (from
> `final now = DateTime.now();` a few lines above where you're editing) and
> already runs on a periodic timer (`gcPeriod`, every 6 hours) — you do not
> need to add any new timer or scheduling, it already exists and already
> calls this function.

#### 7b. Save tombstones to the state file

**FIND THIS** (exact text, appears once):

```dart
      file.writeAsStringSync(jsonEncode({
        'pairings': pairs,
        'names': _persistedNames,
        'secrets': _persistedSecrets,
        'lastSeen': {
          for (final e in _persistedLastSeen.entries)
            e.key: e.value.toIso8601String(),
        },
      }));
```

**REPLACE WITH:**

```dart
      file.writeAsStringSync(jsonEncode({
        'pairings': pairs,
        'names': _persistedNames,
        'secrets': _persistedSecrets,
        'lastSeen': {
          for (final e in _persistedLastSeen.entries)
            e.key: e.value.toIso8601String(),
        },
        'tombstones': {
          for (final e in _pairTombstones.entries)
            e.key: e.value.toIso8601String(),
        },
      }));
```

#### 7c. Load tombstones back from the state file

**FIND THIS** (exact text, appears once):

```dart
      final lastSeen = data['lastSeen'];
      if (lastSeen is Map) {
        lastSeen.forEach((id, ts) {
          if (id is String && id.isNotEmpty && ts is String) {
            final t = DateTime.tryParse(ts);
            if (t != null) _persistedLastSeen[id] = t;
          }
        });
      }
```

**REPLACE WITH:**

```dart
      final lastSeen = data['lastSeen'];
      if (lastSeen is Map) {
        lastSeen.forEach((id, ts) {
          if (id is String && id.isNotEmpty && ts is String) {
            final t = DateTime.tryParse(ts);
            if (t != null) _persistedLastSeen[id] = t;
          }
        });
      }
      final tombstones = data['tombstones'];
      if (tombstones is Map) {
        tombstones.forEach((key, ts) {
          if (key is String && key.isNotEmpty && ts is String) {
            final t = DateTime.tryParse(ts);
            if (t != null) _pairTombstones[key] = t;
          }
        });
      }
```

*Why (7a–7c together):* without persistence, a tombstone would only live in
memory and be forgotten the instant the server process restarts — which
would defeat the entire point, since the whole bug is specifically about
what happens *across restarts*. `_saveState`/`_loadState` are the file's
existing, already-correct read/write functions for the state file; we're
just adding one more field (`tombstones`) alongside the ones that already
exist (`pairings`, `names`, `secrets`, `lastSeen`), following the exact same
pattern each of those already uses.

---

## 5. Verification

### 5.1 Sanity-check the file still parses

After all 7 edits, confirm the file has no obviously broken syntax: open
`app/lib/services/signaling_server.dart` and check that:
- Every `{` you added has a matching `}`.
- You did not duplicate any line.
- The function `_onRegister` still starts with
  `Future<void> _onRegister(_Conn conn, Map<String, dynamic> msg) async {`
  and still ends with a single closing `}` before the next function,
  `_onPairWithCode`.

If a Dart/Flutter toolchain is available, run:

```bash
cd app
flutter analyze
```

and confirm no new errors appear in `signaling_server.dart`.

### 5.2 Run the existing test suite

```bash
cd app
flutter test
```

Pay particular attention to these existing files, which exercise exactly the
code paths touched above and must still pass unmodified:
- `app/test/signaling_server_test.dart`
- `app/test/unpair_reconciliation_test.dart`

### 5.3 (Recommended) Add a regression test for this exact bug

Add a new test to `app/test/signaling_server_test.dart`, in the same
`group('SignalingServer (embedded Dart port)', () { ... })` block as the
existing tests, right after the test named
`'register restores pairings on a fresh host (host failover)'`. This test
simulates the exact bug report: A and B pair, B "unpairs" A while A is not
connected, and then A reconnects and dishonestly re-reports the old pairing
— the server must refuse it and tell A to drop it.

```dart
    test('an explicit unpair is not resurrected by a stale reconnect (ghost pairing)',
        () async {
      final a = await connect(port);
      final b = await connect(port);

      a.sendText({'type': 'register', 'deviceId': 'A', 'deviceName': 'Dev A'});
      await a.nextJson('registered');
      b.sendText({'type': 'register', 'deviceId': 'B', 'deviceName': 'Dev B'});
      await b.nextJson('registered');

      a.sendText({'type': 'create_pairing'});
      final code = (await a.nextJson('pairing_created'))['code'] as String;
      b.sendText({'type': 'pair_with_code', 'code': code});
      await b.nextJson('paired');
      await a.nextJson('paired');

      // Simulate "A goes offline": close A's socket without unpairing.
      await a.close();
      // A short delay lets the server notice the disconnect.
      await Future.delayed(const Duration(milliseconds: 100));

      // B unpairs A while A is offline.
      b.sendText({'type': 'unpair', 'peerId': 'A'});
      await b.nextJson('unpaired');

      // A reconnects and — because it went offline before the unpair — still
      // (dishonestly, from its own stale local cache) reports B as a peer.
      final a2 = await connect(port);
      a2.sendText({
        'type': 'register',
        'deviceId': 'A',
        'deviceName': 'Dev A',
        'pairings': [
          {'deviceId': 'B', 'deviceName': 'Dev B'},
        ],
      });
      await a2.nextJson('registered');

      // The server must NOT resurrect the pairing. Instead it must actively
      // tell A to drop it.
      final unpaired = await a2.nextJson('unpaired');
      expect((unpaired['peer'] as Map)['deviceId'], 'B');

      final state = await a2.nextJson('state');
      final pairings = state['pairings'] as List;
      expect(
        pairings.whereType<Map>().where((p) => p['deviceId'] == 'B'),
        isEmpty,
        reason: 'a tombstoned pairing must not be reported back to the client',
      );

      await a2.close();
      await b.close();
    });
```

Run it with:

```bash
cd app
flutter test test/signaling_server_test.dart
```

It should pass. Before the fix in this document was applied, this same test
would fail (the server would resurrect the pairing instead of sending
`unpaired`).

### 5.4 Manual, real-device confirmation (optional, matches the original bug report exactly)

1. Pair Device 1 and Device 2. Share a song from Device 2 to Device 1.
2. Force-quit Device 1.
3. On Device 2, unpair Device 1 (Devices screen → remove device).
4. Reopen Device 1 **while it can reach Device 2 on the same network** (this
   is required for the fix to have a chance to run — see the limitation
   below).
5. Confirm: Device 1 shows "not paired" to Device 2, and the song that came
   from Device 2 is gone from Device 1's library. Device 2 still shows "not
   paired." Both devices now agree.

---

## 6. Known limitation (not fixed by this plan, and cannot be, by design)

If Device 1 reopens in a situation where it **never** manages to discover or
connect to Device 2's host (different Wi-Fi network, firewall blocking LAN
discovery, Device 2 not currently running, etc.), Device 1 will keep hosting
itself from its own last-known-good local state file, which still shows the
old pairing — because zero information has passed between the two devices in
that situation. This is not something any code change can fix, because it
would require Device 1 to know something it was never told. As soon as the
two devices are able to see each other again (which the app already
periodically attempts on its own, via its existing host-election/discovery
logic), the fix in this document takes over and corrects the ghost
pairing immediately.

---

## 7. Checklist

- [ ] Edit 1 applied (tombstoneTtl constant + doc comment)
- [ ] Edit 2 applied (`_pairTombstones` map + helper functions)
- [ ] Edit 3 applied (`_onRegister` checks tombstone before restoring)
- [ ] Edit 4 applied (`_onRegister` sends `unpaired` for revoked peers)
- [ ] Edit 5 applied (`_addPair` clears tombstone)
- [ ] Edit 6 applied (`_removePair` creates tombstone)
- [ ] Edit 7a applied (GC expires old tombstones)
- [ ] Edit 7b applied (`_saveState` writes tombstones)
- [ ] Edit 7c applied (`_loadState` reads tombstones)
- [ ] `flutter analyze` shows no new errors (if toolchain available)
- [ ] `flutter test` passes, including existing pairing/unpair tests
- [ ] New regression test (section 5.3) added and passing
- [ ] Manual repro (section 5.4) confirmed fixed, if you have real devices
