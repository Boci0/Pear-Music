# Fix Plan: Four Additional Weaknesses in Pear-Music

**Repo:** https://github.com/Boci0/Pear-Music.git
**This plan is SEPARATE from, and independent of, the ghost-pairing fix plan
(`GHOST_PAIRING_FIX_PLAN.md`).** You can apply this plan whether or not you've
applied that one — the edits below don't touch the same lines and don't
depend on each other.

**Files you will edit:**
- `app/lib/services/sync_service.dart` (1 edit)
- `app/lib/services/signaling_server.dart` (4 edits)
- `app/test/sync_integration_test.dart` (2 additions — new regression test)
- `app/test/signaling_server_test.dart` (3 additions — new regression tests)

> **How to use this document if you are an AI coding agent:** same rules as
> the ghost-pairing plan. Each edit gives you an exact `FIND THIS` block
> (search verbatim, occurs once) and an exact `REPLACE WITH` block. Apply
> edits **in the order given** — they are ordered from safest/most isolated
> to most sensitive on purpose. **After every single edit, stop and run the
> verification step listed for that edit before moving to the next one.**
> Do not batch all edits together and test once at the end — if something
> breaks, you want to know which one caused it. Do not reformat or
> "improve" anything beyond what's specified.

---

## Overview: what's being fixed, and why the order matters

| # | Weakness | File | Risk if this fix is wrong |
|---|----------|------|---------------------------|
| 1 | Received files: only size is checked, never content | `sync_service.dart` | Low — self-contained, reuses an existing, already-tested failure path |
| 2 | No size limit on incoming text/control WebSocket frames | `signaling_server.dart` | Low — purely additive, new code path only triggers on a huge frame |
| 3 | `X-Forwarded-For` header trusted from any client by default | `signaling_server.dart` | Medium — changes what "the connecting IP" means; could affect rate limiting if you ever run this behind a real proxy (see below) |
| 4 | The host's own device can be impersonated by anyone who knows its `deviceId` (which is not secret) | `signaling_server.dart` | Medium — touches the authentication path used by every device on every registration; depends on fix #3 being in place first |

Fix #4 depends on fix #3 (it uses the same "what IP is this connection
really from" logic), so #3 must go in first. Fixes #1 and #2 are completely
independent of everything else and of each other — do them first since
they're the lowest-risk, to build confidence before touching the
authentication code.

---

## Fix 1 of 4 — Verify received files by content, not just size

### The problem

`app/lib/services/sync_service.dart`, function `_finalizeIncoming`. Today,
when a file finishes downloading from a peer, the ONLY check performed is:

```dart
final length = await inc.file.length();
if (length != inc.song.size) {
  throw Exception('size mismatch: got $length, expected ${inc.song.size}');
}
```

The `checksum` that then gets stored for this song
(`library.addReceivedSong(..., checksum: inc.song.checksum, ...)`) is simply
copied from what the **sender** claimed in its `file_meta` message — it is
never recomputed from the bytes actually written to disk on the receiving
end. Compare this to how a LOCALLY added file works
(`LibraryService.checksum(file)` in `library_service.dart`, which hashes the
real file on disk). A same-length corruption, or a peer that mislabels a
file, is accepted and silently trusted forever.

### The fix

Compute the real checksum of the downloaded file and compare it to what the
sender claimed, in the exact same place the size is already checked, so a
mismatch is treated exactly like a size mismatch already is.

### Edit 1.1 — `app/lib/services/sync_service.dart`

**FIND THIS** (exact text, appears once):

```dart
    try {
      inc.raf.closeSync();
      final length = await inc.file.length();
      if (length != inc.song.size) {
        throw Exception('size mismatch: got $length, expected ${inc.song.size}');
      }
      await library.addReceivedSong(
        id: songId,
        title: inc.song.title,
        fileName: inc.song.fileName,
        size: inc.song.size,
        checksum: inc.song.checksum,
        sourceDeviceId: peerId,
        artwork: inc.song.artwork,
      );
```

**REPLACE WITH:**

```dart
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
```

### Why this is safe / won't break normal transfers

- `LibraryService` is **already imported** at the top of `sync_service.dart`
  (`import 'library_service.dart';`) — no new import needed.
- `LibraryService.checksum(File file)` already exists, is `static`, and is
  already used elsewhere in the same codebase for exactly this purpose
  (`library_service.dart`, `addLocalFiles` / `addScrapedFile`). This edit
  does not add any new hashing logic — it just calls the existing function
  one more place.
- The `catch (e) { ... }` block immediately below this code is **NOT
  changed by this edit** — it already exists, and already: deletes the
  partial file, removes the progress indicator, and re-requests the song
  from the sender up to `maxFinalizeRetries` (2) times. A checksum mismatch
  now simply flows into that same, already-tested path, exactly like a size
  mismatch already does. You are not writing any new error-handling logic.
- In the normal, non-corrupted case, the sender computed `song.checksum`
  from the exact same bytes that get transferred byte-for-byte (the sync
  protocol streams the raw file). So `actualChecksum == inc.song.checksum`
  on every successful transfer — this fix should never fire for a healthy
  transfer. If it ever does fire unexpectedly, that itself is valuable
  signal that something upstream is subtly wrong.
- Performance: this adds one extra full read-and-MD5-hash of the file after
  it's already fully on disk. For typical song-sized files (a few MB to a
  few tens of MB) this is a fraction of a second and happens once, after the
  transfer is already complete — it does not slow down the transfer itself.

### Verification for Fix 1

1. Re-read the ~20 lines around the edit to confirm no duplicated/missing
   braces.
2. Run:
   ```bash
   cd app
   flutter test test/sync_integration_test.dart
   ```
   Every existing test in that file must still pass, in particular:
   - `'a dropped chunk self-heals: failed finalize re-requests the song'`
     (this exercises the exact same catch/retry path your edit now also
     uses — if this test still passes, your edit didn't break that path).
   - `'a stalled download times out and cleans up the partial file'`.
3. Add the new regression test below (section "Regression test 1") and
   confirm it passes. Before this fix, an equivalent test would have
   **passed even though the file was corrupted** (silently accepting bad
   data) — after the fix, it demonstrates the corruption is caught and
   self-healed via a retry, and the final file on disk is correct.

### Regression test 1 — `app/test/sync_integration_test.dart`

This test file already has a fake-channel harness for simulating transport
problems (see the existing `_DropOnceChannel`, used by the "dropped chunk
self-heals" test). Add a sibling class that corrupts one byte instead of
dropping a whole chunk — this is the case the old size-only check could
never catch, because total length is unchanged.

**Step A — add `dart:typed_data` to the imports.**

**FIND THIS** (exact text, appears once, at the top of the file):

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
```

**REPLACE WITH:**

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
```

**Step B — add the new fake channel class, right before `void main() {`.**

**FIND THIS** (exact text, appears once):

```dart
void main() {
  late Directory tempDirA;
```

**REPLACE WITH:**

```dart
/// A fake channel that flips one payload byte in the FIRST binary frame it
/// sends (simulating same-length corruption — e.g. a bit flip — as opposed
/// to a dropped chunk, which changes the total length and is already caught
/// by the size check). Forwards everything after untouched. Used to prove
/// the receiving side verifies the actual checksum of what it downloaded,
/// not just its length.
class _CorruptOnceChannel extends RTCDataChannel {
  _CorruptOnceChannel();

  RTCDataChannel? otherSide;
  bool _corruptNextBinary = true;

  @override
  RTCDataChannelState? get state => RTCDataChannelState.RTCDataChannelOpen;

  @override
  int? get id => 1;

  @override
  String? get label => 'peerm';

  @override
  int? get bufferedAmount => 0;

  @override
  Future<void> send(RTCDataChannelMessage message) async {
    if (message.isBinary && _corruptNextBinary && message.binary.isNotEmpty) {
      _corruptNextBinary = false;
      // Flip the last byte (always part of the payload, after the fixed
      // [magic][idLen][songId][index][total] header) — same length, wrong
      // content.
      final corrupted = Uint8List.fromList(message.binary);
      corrupted[corrupted.length - 1] ^= 0xFF;
      otherSide?.onMessage
          ?.call(RTCDataChannelMessage.fromBinary(corrupted));
      return;
    }
    otherSide?.onMessage?.call(message);
  }

  @override
  Future<void> close() async {}
}

void main() {
  late Directory tempDirA;
```

**Step C — add the test itself, right before the `'a stalled download
times out...'` test.**

**FIND THIS** (exact text, appears once):

```dart
  test('a stalled download times out and cleans up the partial file',
```

**REPLACE WITH:**

```dart
  test(
      'same-length corruption is caught by checksum verification and self-heals',
      () async {
    // A song big enough to span several chunks. The first chunk arrives with
    // one flipped byte — same total length as expected, so the OLD
    // size-only check would have silently accepted it. The checksum check
    // must catch the mismatch, causing the same self-heal (re-request) path
    // as a dropped chunk uses.
    await libA.addLocalFiles([makeAudio('corrupt.mp3', 200_000)]);

    final chA = _CorruptOnceChannel();
    final chB = _FakeChannel();
    chA.otherSide = chB;
    chB.otherSide = chA;
    syncA.attachChannel('device-B', chA);
    syncB.attachChannel('device-A', chB);

    await waitFor(() => libB.songs.length == 1);
    expect(libB.songs.first.sourceDeviceId, 'device-A');

    final orig = await libA.songFile(libA.songs.first).readAsBytes();
    final copy = await libB.songFile(libB.songs.first).readAsBytes();
    expect(orig.length, copy.length);
    expect(orig, copy,
        reason: 'the corrupted first attempt must never be kept — only the '
            'clean retry should end up on disk');
    expect(libB.songs.first.checksum, libA.songs.first.checksum);

    await syncA.idle;
    await syncB.idle;
  });

  test('a stalled download times out and cleans up the partial file',
```

Run: `cd app && flutter test test/sync_integration_test.dart` — this new
test, plus every pre-existing test in the file, must pass.

---

## Fix 2 of 4 — Cap the size of incoming text/control frames

### The problem

`app/lib/services/signaling_server.dart`, function `_handleMessage`. Binary
frames are already capped:

```dart
if (data is! String) {
  final bytes = ...;
  if (bytes.length > maxPayload) { ...close...; return; }
  ...
}
```

But **text frames have no size check at all** before the code proceeds to
rate-limit and `jsonDecode` them. Since the "server" here is frequently just
someone's phone (any device can become the host), an arbitrarily large text
frame is a cheap way to spike memory on that device.

### The fix

Add the same kind of cap already used for binary frames, sized generously
enough that it will never affect a real (even very large) library sync.

### Edit 2.1 — add the constant

**FIND THIS** (exact text, appears once):

```dart
  // ---- Limits (mirror server/src/index.js) ----
  static const int maxPayload = 2 * 1024 * 1024; // 2 MB per frame
  static const int maxConnsPerIp = 8;
```

**REPLACE WITH:**

```dart
  // ---- Limits (mirror server/src/index.js) ----
  static const int maxPayload = 2 * 1024 * 1024; // 2 MB per frame
  // Text/control frames (register, manifest, etc.) had no size cap at all —
  // only binary chunk frames did. A single oversized text frame could spike
  // memory before the rate limiter or JSON decode ever runs, on what may
  // just be someone's phone. Generous enough for a very large library's
  // manifest, far below "unbounded".
  static const int maxTextPayload = 4 * 1024 * 1024; // 4 MB per text frame
  static const int maxConnsPerIp = 8;
```

### Edit 2.2 — enforce it in `_handleMessage`

**FIND THIS** (exact text, appears once):

```dart
      return;
    }

    // Text message: rate-limit control traffic (binary frames are excluded —
    // they are already paced by relay_ack).
    if (!conn.controlLimiter.allow()) {
```

**REPLACE WITH:**

```dart
      return;
    }

    // Text (control) frame: bound its size before doing any work on it (rate
    // limiting, JSON decode) — same idea as the binary cap above, just for
    // text frames, which previously had no limit at all.
    if (data.length > maxTextPayload) {
      try {
        conn.ws.close(1009, 'message too big');
      } catch (_) {}
      return;
    }

    // Text message: rate-limit control traffic (binary frames are excluded —
    // they are already paced by relay_ack).
    if (!conn.controlLimiter.allow()) {
```

> Note: `data` is the function's `dynamic` parameter. By this point in the
> function, the preceding `if (data is! String) { ...; return; }` block
> guarantees whatever reaches this line really is a `String` at runtime
> (the function already calls `jsonDecode(data)` a few lines further down
> without an explicit cast, using the exact same assumption) — `data.length`
> works the same way and needs no new cast or import.

### Why this is safe

- **4 MB is a deliberately generous ceiling.** A `manifest` message lists
  every song as compact JSON (id, title, filename, checksum, size — no
  audio data). Even a library of many thousands of songs stays well under
  1 MB of JSON. This cap should never be hit by any real usage; it exists
  purely to bound a malicious/broken sender.
- This is purely additive — a new `if` that returns early only in a case
  that was previously unhandled. It cannot change behavior for any message
  under 4 MB, which is every legitimate message the app has ever sent.
- Uses the same close code (`1009`, "message too big") the binary path
  already uses for the same situation, for consistency.

### Verification for Fix 2

1. Run:
   ```bash
   cd app
   flutter test test/signaling_server_test.dart
   ```
   All existing tests must still pass (none of them send anything close to
   4 MB of text).
2. Add the regression test below and confirm it passes.

### Regression test 2 — `app/test/signaling_server_test.dart`

Add this right before the existing `'pairing with a wrong code fails with
an error'` test (anywhere in the same `group(...)` block works; this
location keeps related tests near each other).

**FIND THIS** (exact text, appears once):

```dart
    test('pairing with a wrong code fails with an error', () async {
```

**REPLACE WITH:**

```dart
    test('an oversized text frame is rejected instead of being processed',
        () async {
      final a = await connect(port);
      // A single text frame well over maxTextPayload (4 MB). It must be
      // rejected (socket closed) before it's ever JSON-decoded, not
      // silently accepted like every text frame used to be.
      final huge = 'x' * (SignalingServer.maxTextPayload + 1024);
      a.ws.add(huge);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (a.ws.readyState == WebSocket.open &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(a.ws.readyState, isNot(WebSocket.open),
          reason: 'an oversized text frame must close the connection');
      await a.close();
    });

    test('pairing with a wrong code fails with an error', () async {
```

> This test deliberately waits only 5 seconds (shorter than the unrelated
> 10-second `registerTimeout`), so a passing result can only mean the new
> size check fired — not that the connection was closed for an unrelated
> reason (never registering).

Run: `cd app && flutter test test/signaling_server_test.dart` — this new
test, plus every pre-existing test, must pass.

---

## Fix 3 of 4 — Stop trusting a client-supplied `X-Forwarded-For` by default

### The problem

`app/lib/services/signaling_server.dart`, function `_clientIp`:

```dart
String _clientIp(HttpRequest req) {
  // Behind a proxy the real IP is in x-forwarded-for.
  final xff = req.headers.value('x-forwarded-for');
  if (xff != null && xff.trim().isNotEmpty) {
    return xff.split(',').first.trim();
  }
  return req.connectionInfo?.remoteAddress.address ?? 'unknown';
}
```

This is carried over from the optional Node.js reference server
(`server/src/index.js`), which genuinely IS meant to run behind a real
hosting-platform proxy (Render, Railway, etc.) — see that file's own
comment: *"Behind a TLS proxy (Render/Railway etc.) x-forwarded-for is the
real IP."* But `signaling_server.dart` is the **embedded, on-device**
server every phone/PC runs directly, reachable straight from the LAN with
nothing in front of it. In that setup, `X-Forwarded-For` is just another
HTTP header any WebSocket client can set to literally anything — there is
no proxy to have written it truthfully. Trusting it lets a remote client:
- claim to be any IP it wants, defeating the per-IP connection cap
  (`maxConnsPerIp`) a few lines below in the same file, and
- (after Fix 4 below is applied) claim to be `127.0.0.1` to defeat a
  loopback check.

### The fix

Add an explicit, **opt-in, default-`false`** constructor flag,
`trustProxyHeaders`. Only consult the header when that flag is explicitly
set to `true`; otherwise always use the real TCP peer address (which a
client cannot spoof).

### Edit 3.1 — add the constructor parameter and field

**FIND THIS** (exact text, appears once):

```dart
  SignalingServer({
    required this.port,
    this.host = '0.0.0.0',
    this.stateFile,
    this.onLog,
    this.advertiseName = 'Pear Music device',
    this.advertiseDeviceId,
  });

  final int port;
  final String host;
  final File? stateFile;
  final void Function(String message)? onLog;
```

**REPLACE WITH:**

```dart
  SignalingServer({
    required this.port,
    this.host = '0.0.0.0',
    this.stateFile,
    this.onLog,
    this.advertiseName = 'Pear Music device',
    this.advertiseDeviceId,
    this.trustProxyHeaders = false,
  });

  final int port;
  final String host;
  final File? stateFile;
  final void Function(String message)? onLog;

  /// Whether to trust a client-supplied `X-Forwarded-For` header as the
  /// connecting IP. Only meaningful if this server is actually deployed
  /// behind a real reverse proxy (it isn't, for the embedded on-device
  /// server this app runs — see [_clientIp]). Defaults to false so a remote
  /// WebSocket client can't just claim to be any IP it likes.
  final bool trustProxyHeaders;
```

### Edit 3.2 — use the flag in `_clientIp`

**FIND THIS** (exact text, appears once):

```dart
  String _clientIp(HttpRequest req) {
    // Behind a proxy the real IP is in x-forwarded-for.
    final xff = req.headers.value('x-forwarded-for');
    if (xff != null && xff.trim().isNotEmpty) {
      return xff.split(',').first.trim();
    }
    return req.connectionInfo?.remoteAddress.address ?? 'unknown';
  }
```

**REPLACE WITH:**

```dart
  String _clientIp(HttpRequest req) {
    // Behind a REAL reverse proxy the true client IP is in x-forwarded-for.
    // This embedded, on-device server is normally reached directly (it's a
    // zero-config LAN server, not something deployed behind a proxy), so any
    // WebSocket client could set this header to whatever it likes. Only
    // trust it when explicitly opted in via [trustProxyHeaders]; otherwise
    // always use the real TCP peer address, which a client cannot spoof.
    if (trustProxyHeaders) {
      final xff = req.headers.value('x-forwarded-for');
      if (xff != null && xff.trim().isNotEmpty) {
        return xff.split(',').first.trim();
      }
    }
    return req.connectionInfo?.remoteAddress.address ?? 'unknown';
  }
```

### Why this is safe / how it could theoretically affect someone

- **Every existing caller is unaffected.** Search the codebase for
  `SignalingServer(` — `app/lib/main.dart` is the only place that
  constructs one for real use, and it does not pass `trustProxyHeaders`, so
  it gets the new default (`false`). Every test that constructs a
  `SignalingServer` also doesn't pass it, so they all get `false` too,
  which — for a WebSocket test client connecting to `127.0.0.1` — is
  **exactly the same effective IP result as before** (no `X-Forwarded-For`
  header is sent in any existing test, so the old code would have fallen
  through to `req.connectionInfo?.remoteAddress.address` anyway, which is
  identical to what the new code does by default). Confirmed by inspection:
  `grep -rn "x-forwarded-for" app/test` returns nothing — no test relies on
  the header being honored.
- **The only behavior change is for a connection that explicitly sends
  `X-Forwarded-For`.** Nothing in the real app ever does this today (the
  app's own client, `signaling_service.dart`, never sets that header when
  connecting). So this change has zero effect on any normal user's traffic.
- **If you personally run the embedded server behind a real reverse proxy**
  (an unusual, advanced setup — not how the app is designed to run), you
  would need to explicitly pass `trustProxyHeaders: true` when constructing
  it in `main.dart` to keep the old behavior. This plan does not do that
  for you, since it's not the app's normal deployment model — flagging it
  here so you can make that call if it applies to you.

### Verification for Fix 3

1. Run the FULL test suite, not just one file, since `_clientIp` is used by
   every connection, in every test:
   ```bash
   cd app
   flutter test
   ```
   Everything must still pass — if anything in `signaling_server_test.dart`
   fails here, stop and re-check this edit before continuing to Fix 4.
2. This fix has no user-visible behavior on its own (nothing currently
   sends the header) — its regression tests are combined with Fix 4's,
   since that's the fix that actually depends on IP-based decisions. See
   "Regression tests 3 & 4" below.

---

## Fix 4 of 4 — Restrict the "host's own device" auth bypass to loopback

**Apply this only after Fix 3 is in place and verified — it uses the same
`conn.ip` value Fix 3 makes trustworthy.**

### The problem

`app/lib/services/signaling_server.dart`, function `_onRegister`:

```dart
final isOwnDevice = advertiseDeviceId != null && advertiseDeviceId == id;
if (isOwnDevice) {
  // ...skips the secret check, adopts whatever secret was given...
```

`advertiseDeviceId` is the host device's own persistent id. It is **not a
secret** — it's broadcast in the clear, every 10 seconds, over UDP
multicast, and served by the unauthenticated `/discover` HTTP endpoint
(`_helloJson()`, same file), specifically so other devices can find this
host to pair with it. That's fine for its intended purpose (discovery). The
problem is this same public value is *also* used as sole proof of identity
to skip the password-like secret check. Any device on the LAN that learns
the host's `deviceId` (trivially, via the discovery mechanism that's
supposed to be public) can register claiming to be that same id, which:
- disconnects the real host's own local app connection
  (`existing.ws.close(4001, 'replaced')`, a few lines above), and
- inherits `conn.pairings` seeded from that id's persisted pairings — i.e.
  every device paired with the host — putting the impostor in a position to
  receive relay/signal traffic (including file transfer chunks) meant for
  the host.

### The fix

The host's own app only ever reconnects to itself via
`ws://localhost:<port>` (see `AppController._ensureConnection` and
`_takeOverAsHost` in `app_controller.dart` — both hardcode `localhost`).
Restrict the bypass to connections that are actually from loopback.

### Edit 4.1 — `app/lib/services/signaling_server.dart`

**FIND THIS** (exact text, appears once):

```dart
    // The host's OWN device is always authorized on its own server. During a
    // host failover the client secret was issued by the PREVIOUS host's server
    // and may not match the secret persisted in THIS host's state file - so
    // instead of locking itself out, adopt the client's secret (or re-bind a
    // fresh one) and let it in.
    final isOwnDevice = advertiseDeviceId != null && advertiseDeviceId == id;
    if (isOwnDevice) {
```

**REPLACE WITH:**

```dart
    // The host's OWN device is always authorized on its own server. During a
    // host failover the client secret was issued by the PREVIOUS host's server
    // and may not match the secret persisted in THIS host's state file - so
    // instead of locking itself out, adopt the client's secret (or re-bind a
    // fresh one) and let it in.
    //
    // IMPORTANT: `advertiseDeviceId` is NOT a secret — it's broadcast in the
    // clear over LAN discovery (multicast hello + the /discover endpoint) so
    // other devices can find this host to pair with it. Matching it alone is
    // not proof this connection is really the host's own app; anyone on the
    // LAN could otherwise claim it and skip the secret check entirely. The
    // host's own app only ever reconnects to itself over loopback
    // (`ws://localhost:<port>` — see AppController._ensureConnection /
    // _takeOverAsHost), so this bypass is additionally restricted to
    // loopback connections. A non-loopback connection claiming the same id
    // still goes through the normal secret check in the `else` branch below.
    final isLoopback = conn.ip == '127.0.0.1' || conn.ip == '::1';
    final isOwnDevice =
        advertiseDeviceId != null && advertiseDeviceId == id && isLoopback;
    if (isOwnDevice) {
```

### Why this is safe / careful analysis of edge cases

- **The one existing test that exercises this exact branch already connects
  over loopback.** `signaling_server_test.dart`, test
  `"the host's own device can always register (no self-lockout after
  failover)"` connects via the shared `connect()` helper, which does
  `WebSocket.connect('ws://127.0.0.1:$port')` — genuinely loopback. This
  test's behavior is unchanged by this edit and must still pass exactly as
  before.
- **Every test in the file connects via `127.0.0.1`.** Confirmed by
  inspection: `grep -n "WebSocket.connect" app/test/signaling_server_test.dart`
  shows exactly one call site, using the literal address `127.0.0.1`, used
  by every test. So this edit cannot spuriously break any *other* existing
  test either — none of them were relying on a non-loopback connection
  being treated as the host's own device (that was never a legitimate use
  case, only an accidental side door).
- **Race condition check — a device racing to claim the id first:**
  suppose, hypothetically, a remote attacker registers as `advertiseDeviceId`
  *before* the real host's own local client has registered for the first
  time (so `_persistedSecrets[id]` doesn't exist yet). Walking through the
  code: the attacker's connection isn't loopback, so it takes the normal
  `else` branch; since there's no existing secret yet, it's allowed to
  register and bind a secret of its own choosing (exactly the same as any
  brand-new device id would be — this is not a new behavior introduced by
  this edit). When the REAL host's own app then registers over loopback
  with the same id, `isLoopback` is `true` and `advertiseDeviceId == id` is
  `true`, so `isOwnDevice` is `true` regardless of what happened moments
  earlier — the host always reclaims its own id's secret the moment it
  registers from loopback, overwriting whatever the attacker set. So the
  legitimate device is never locked out by this race, and this edit is
  strictly more protective than the old code in every case, not just the
  common one.
- **Both common loopback address forms are covered** (`127.0.0.1` and
  `::1`, for IPv4 and IPv6 stacks respectively), matching how
  `dart:io`'s `req.connectionInfo?.remoteAddress.address` reports a
  same-machine connection.

### Verification for Fix 4

1. Run the FULL test suite:
   ```bash
   cd app
   flutter test
   ```
   Pay special attention to `signaling_server_test.dart` — every test in it
   must pass, especially the pre-existing
   `"the host's own device can always register (no self-lockout after
   failover)"` test.
2. Add the two regression tests below and confirm they pass.
3. **Manual smoke test (recommended given this touches auth):** on a real
   device, force a host failover the normal way (see the ghost-pairing
   plan's manual repro steps for how to do this), and confirm the device
   that becomes host can always reconnect to its own embedded server
   normally, with no new "unauthorized" errors and no unexpected
   disconnect loops. This is the one behavior this edit must never break —
   the comment right above the code literally says "the host can never
   lock itself out," and this edit must keep that true.

### Regression tests 3 & 4 — `app/test/signaling_server_test.dart`

Add these two tests right after the existing `"the host's own device can
always register (no self-lockout after failover)"` test (they demonstrate
Fix 3 and Fix 4 together, since Fix 4 depends on Fix 3).

**FIND THIS** (exact text, appears once — this is the END of the existing
test, immediately followed by a blank line before the next test):

```dart
        await host.close();
        await peer.close();
        await impostor.close();
      } finally {
        await s.stop();
      }
    });

```

**REPLACE WITH:**

```dart
        await host.close();
        await peer.close();
        await impostor.close();
      } finally {
        await s.stop();
      }
    });

    test(
        'a spoofed X-Forwarded-For is ignored by default (own-device bypass '
        'still keys off the REAL loopback address)', () async {
      // trustProxyHeaders defaults to false — a client-supplied header must
      // not change what IP the server thinks this connection is from.
      final s = SignalingServer(
          port: 0, host: '127.0.0.1', advertiseDeviceId: 'HOST');
      await s.start();
      try {
        final ws = await WebSocket.connect(
          'ws://127.0.0.1:${s.boundPort}',
          headers: {'X-Forwarded-For': '203.0.113.5'},
        );
        final c = _Client(ws)..listen();
        // Claims to be the host's own device with a stale/wrong secret. This
        // must still be ACCEPTED: the real TCP peer is loopback regardless
        // of the forged header, so the own-device bypass still applies.
        c.sendText({
          'type': 'register',
          'deviceId': 'HOST',
          'deviceName': 'Host',
          'secret': 'STALE',
        });
        final reg = await c.nextJson('registered');
        expect(reg['secret'], 'STALE');
        await c.close();
      } finally {
        await s.stop();
      }
    });

    test(
        'a non-loopback address (only reachable by opting into '
        'trustProxyHeaders) cannot bypass the own-device secret check',
        () async {
      final s = SignalingServer(
        port: 0,
        host: '127.0.0.1',
        advertiseDeviceId: 'HOST',
        trustProxyHeaders: true,
      );
      await s.start();
      try {
        // Establish the host's real secret via a normal (loopback, no
        // forwarded-for) connection.
        final host = await connect(s.boundPort);
        host.sendText({
          'type': 'register',
          'deviceId': 'HOST',
          'deviceName': 'Host',
          'secret': 'REAL',
        });
        await host.nextJson('registered');
        await host.close();

        // An attacker on the LAN learns 'HOST' from discovery (it's public)
        // and connects claiming a non-loopback address (only possible here
        // because this server opted into trustProxyHeaders) with the WRONG
        // secret. Since the claimed address isn't loopback, the own-device
        // bypass must NOT apply — normal secret auth kicks in and rejects it.
        final attacker = await WebSocket.connect(
          'ws://127.0.0.1:${s.boundPort}',
          headers: {'X-Forwarded-For': '203.0.113.5'},
        );
        final c = _Client(attacker)..listen();
        c.sendText({
          'type': 'register',
          'deviceId': 'HOST',
          'deviceName': 'Host',
          'secret': 'WRONG',
        });
        final err = await c.nextJson('error');
        expect(err['message'], 'unauthorized');
        await c.close();
      } finally {
        await s.stop();
      }
    });

```

> Both new tests connect with `WebSocket.connect(..., headers: {...})`
> directly (rather than the shared `connect()` helper) because the helper
> doesn't take custom headers — this is the standard `dart:io` way to set a
> header on a WebSocket upgrade request, nothing new needs to be imported.

Run: `cd app && flutter test test/signaling_server_test.dart` — all tests,
old and new, must pass.

---

## Full verification checklist (run this after all four fixes are applied)

```bash
cd app
flutter analyze                          # no new errors/warnings
flutter test                             # entire suite passes
flutter test test/sync_integration_test.dart     # Fix 1
flutter test test/signaling_server_test.dart     # Fixes 2, 3, 4
```

- [ ] Fix 1 applied (`sync_service.dart`: checksum verification)
- [ ] Fix 1 regression test added and passing
- [ ] Fix 2 applied (`signaling_server.dart`: `maxTextPayload` constant + check)
- [ ] Fix 2 regression test added and passing
- [ ] Fix 3 applied (`signaling_server.dart`: `trustProxyHeaders` flag, default false)
- [ ] Fix 4 applied (`signaling_server.dart`: loopback-restricted `isOwnDevice`)
- [ ] Fixes 3 & 4 regression tests added and passing
- [ ] Full `flutter test` suite passes with no regressions
- [ ] `flutter analyze` shows no new errors
- [ ] Manual smoke test: pair two real devices, transfer a song, force a
      host failover, confirm the failed-over host reconnects to itself
      without any new "unauthorized" errors

## If something breaks

Each fix in this plan is self-contained to the edit(s) listed under it. If
`flutter test` fails after a specific fix:
1. Re-read that fix's "Why this is safe" section — it lists the exact
   assumptions the fix relies on (e.g. "no test sends `X-Forwarded-For`").
   If a failing test contradicts one of those assumptions, that's the bug
   to look at first.
2. You can safely revert just that one fix (undo only its `FIND
   THIS`/`REPLACE WITH` edit(s), leaving earlier fixes in place) since the
   fixes don't share code paths with each other, except that Fix 4 needs
   Fix 3 to already be applied.
3. None of these fixes need to be applied all-or-nothing — it's fine to
   ship Fix 1 and Fix 2 (the lowest-risk ones) even if you decide to hold
   off on Fix 3/Fix 4 for further review.
