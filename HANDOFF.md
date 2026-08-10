# PEAR MUSIC — DEV HANDOFF (2026-08-10)

> Self-contained handoff so a fresh chat/agent can pick up immediately. Read the
> **TL;DR** first, then the **Current regressions** section.

---

## TL;DR — where we are right now

**Project**: Pear Music — a local-first, peer-to-peer music sync app (Flutter, Windows + Android, one codebase at `app/`). No cloud, no accounts. Devices pair with a 6-char code, and songs added on one device sync to all paired devices over a local relay.

**Regression in progress**: **song sync is broken on real devices.** The laptop UI shows "sending", but no files arrive on the phone.

- **Root cause FOUND and FIXED (uncommitted as of this doc)**: the embedded server drops the `e:1` encryption flag when it forwards the binary-relay marker. The receiver therefore treats the encrypted chunk as plaintext → `Invalid UTF-8 byte` in `SyncService._onBinary` → `finalize failed: size mismatch: got 0, expected N`.
- The fix is applied to **both** `app/lib/services/signaling_server.dart` and `server/src/index.js`, plus a regression test. **It has NOT been verified end-to-end on-device yet.**
- A **second regression was observed after redeploy**: the phone's identity **changed** (deviceId `bdc33e9b...` "Phone" → `b1e25505...` "localhost"). If the phone's persisted identity was reset, its pairing (keyed by deviceId) is broken → need to re-pair. **Needs investigation.**

**Recommended next step for the new chat**: commit the pending e:1 fix, then reproduce a real device↔device sync with the phone connected over USB (`adb logcat -s flutter` for logs). Confirm:
1. `[e2e] deriving shared key for <peerId>` appears (E2E key exchange works).
2. No `Invalid UTF-8 byte` / `size mismatch: got 0` errors.
3. Files arrive and finalize (no `finalize failed`).
Then investigate why the phone's deviceId changed.

---

## Current regressions (detailed)

### 1. Song sync broken — root cause found & fixed (pending verify)

**Symptom** (user): "it says sending on my laptop but no files sent to my phone."

**Phone logcat evidence** (debug build, `adb logcat -s flutter`):
```
[sync] <- 54918717-7512-40bd-8e12-230ad452b2b1: hello (e2ePub: true)
[e2e] deriving shared key for 54918717-7512-40bd-8e12-230ad452b2b1
[server] [relay] PC -> localhost (text)        <- text relay works
[sync] finalize failed <songId>: Exception: size mismatch: got 0, expected 2029381
[pearmusic] Unhandled exception: FormatException: Invalid UTF-8 byte (at offset 1)
  SyncService._onBinary (sync_service.dart:388)
  RelayDataChannel.handleRelayBinary (relay_data_channel.dart:111)
```

**Root cause**: Text relay works (encrypted text decrypted fine). But binary chunks fail: the receiver gets the **encrypted frame and does NOT decrypt it**, so `_onBinary` tries to parse raw ciphertext.

Why: the sender (PC) sends a marker `{type:'relay', to, data:{t:'bin', e:1}}` followed by the raw encrypted frame. The **server** forwards the marker to the receiver as:

```dart
target.send({'type': 'relay', 'from': id, 'data': {'t': 'bin'}});   // e:1 DROPPED
```

The receiver sets `_pendingRelayBinaryEnc = data['e'] == 1` = **false**, then hands the raw ciphertext to the parser.

**Why it regressed now**: E2E encryption was silently OFF for real devices until the "E2E key never generated at startup" fix (commit `78ce13c`) made it actually turn on. Before that, markers had no `e:1`, so dropping `e` was harmless. Now every chunk is encrypted, and the dropped flag breaks decryption.

**The fix (already applied, uncommitted)**:
- `app/lib/services/signaling_server.dart` (~line 443): forward the flag →
  ```dart
  final e = (data is Map<String, dynamic>) ? data['e'] : null;
  target.send({
    'type': 'relay',
    'from': id,
    'data': {'t': 'bin', if (e == 1) 'e': 1},
  });
  ```
- `server/src/index.js` (~line 528): same fix →
  ```js
  send(target.ws, {
    type: 'relay',
    from: deviceId,
    data: { t: 'bin', ...(msg.data?.e === 1 ? { e: 1 } : {}) },
  });
  ```
- Regression test added: `app/test/signaling_server_test.dart` (relays `{t:'bin', e:1}` and asserts the receiver's marker carries `e:1`). Passes; `flutter analyze` clean.

**Status**: fix applied + unit-tested, both platforms rebuilt + deployed, but **not yet confirmed working on-device** (the phone's latest logs show it failed to reach the PC and took over as host before any sync could be tested — see #2).

### 2. Phone identity changed / host flapping (investigate)

**Observation** (after redeploying the e:1 fix): the phone's logcat shows:

```
[signaling] connect failed: TimeoutException after 0:00:10.000000  (to ws://10.84.188.119:8080)
[host] taking over as host
[server] Pear Music signaling server listening on 0.0.0.0:8080 (ws)
[server] [register] localhost (b1e25505-8de2-42c7-af72-14ace8b912c1)
```

- The phone could NOT reach the PC's server (`10.84.188.119:8080`) → 10s timeout → it took over as host (this is the intended failover).
- **The phone registered as a NEW device**: deviceId `b1e25505...`, name `localhost`. Previously it was `bdc33e9b...` named "Phone".
- This means the phone's **SharedPreferences identity was reset** (deviceId/deviceName are persisted in `peerm_device_id` / `peerm_device_name`). A new deviceId means the pairing with the PC (which is keyed by the OLD id) is lost → likely need to re-pair.
- Possible causes to check: `adb install -r` should preserve data, but a phone reboot / "clear data" / app update quirk may have reset it. Check `adb shell run-as com.peerm.peerm_app cat shared_prefs/FlutterSharedPreferences.xml` (only works on a **debuggable** debug build) to see the persisted `peerm_device_id`.

**Also note**: `[discover] answered probe from 100.122.188.165` appears repeatedly — that's the PC on the hotspot sending discovery probes. The phone answers them, so discovery works; the PC just needs to connect to whichever device is hosting.

---

## How the app works (architecture recap — important context)

- **One codebase** `app/` (Flutter, Windows + Android). Embedded pure-Dart signaling server: `app/lib/services/signaling_server.dart` (a `SignalingServer` class). **No Node.js needed** — the app hosts its own relay. `server/` is an optional reference Node implementation.
- **Host election**: "last online device is host". Each device persists `peerm_is_host`. On startup the host starts its server (port 8080) and connects to `ws://localhost:8080`; every other device connects to the host's LAN IP. Failover: a client that can't reach its host takes over as host after ~6s. Periodic reconcile (30s) hands hosting back to the smaller-deviceId device.
- **Pairing**: 6-char code (`ABCDEFGHJKLMNPQRSTUVWXYZ23456789`) or QR. Code-only (no server details in the QR since the zero-config change). Pairing + names persist in the server state file and client-side (`peerm_paired_device_ids` as a JSON map of `deviceId -> name`).
- **Sync transport**: everything goes over the **server relay** (WebSocket), NOT WebRTC (WebRTC was removed — it dropped on phone hotspots). Text control messages + raw binary frames.
- **E2E encryption**: X25519 key exchange (public keys ride in the `hello` handshake) → AES-256-GCM. Both sides derive the same key. Text relay: `{t:'text', e:1, d: base64(nonce||ct||tag)}`. Binary: marker `{t:'bin', e:1}` + raw frame `nonce||ct||tag` (+28 bytes per 64KB chunk). No key → plaintext (backward compatible).
- **Sync protocol** (over the relay): `hello` (with `e2ePub`), `manifest`, `request_songs`, `file_meta`, binary chunks (envelope: `0x50, idLen u16, songId, chunkIndex u32, totalChunks u32, payload`), `file_done`, `song_deleted`, playlist messages. `relay_ack` provides backpressure (one binary chunk in flight per sender).

---

## Recent commit history (all pushed to `main`)

| Commit | What |
|---|---|
| `b510174` | Embed signaling server in-app; Windows builds no longer need Developer Mode |
| `68c2511` | Smart Connect QR + fix debug-only audio notification crash |
| `81d3aee` | LocalSend-style LAN discovery |
| `04dfcae` | Zero-config connection; QR is code-only |
| `817d270` | Host-election model: "last online device is host" + failover + pairing restore |
| `8d24990` | E2E fingerprint verification + 0-paired fix + new pear logo |
| `582ef8f` | Host failover self-lockout fix (own device always authorized; recover stale secrets) |
| `b9a8010` | Faster server switching (6s failover + 30s periodic host reconcile) |
| `246d3ea` | README: ARMv7 download link |
| `57c9fb2` | README: server is embedded (no Node.js) |
| `78ce13c` | **E2E key never generated at startup** (broken fingerprint + encryption silently off) + unpair fix |
| `2fa52e0` | Removed fingerprint verification UI; kept code pairing + automatic E2E encryption |

**UNCOMMITTED right now**: the e:1 binary-marker flag fix (both servers) + regression test + temporary sync tracing (`debugPrint`s in `sync_service.dart`, `signaling_service.dart`, `app_controller.dart`). **Commit this, then verify.**

---

## Build / deploy / test

```powershell
# Analyze + full test suite (currently 71 passing before the new regression test; 7 server tests after)
cd app
flutter analyze
flutter test

# Android debug APK (arm64 split — the phone's ABI)
flutter build apk --debug --split-per-abi
# install + launch (launcher activity is AudioServiceActivity, NOT .MainActivity)
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-debug.apk
adb logcat -c
adb shell am force-stop com.peerm.peerm_app
adb shell am start -n com.peerm.peerm_app/com.ryanheise.audioservice.AudioServiceActivity

# Windows release
flutter build windows --release   # -> build\windows\x64\runner\Release\peerm_app.exe

# Node reference server tests (after the index.js fix)
cd server
node test/smoke.js
```

- **Flutter**: `C:\Users\muhdb\AppData\Local\FlutterSDK\flutter` (Flutter 3.44.9 / Dart 3.12.2). NOTE: this SDK is **patched locally** so Windows builds work without Developer Mode (junctions instead of symlinks, via a temp `.bat` + `mklink /J`). Backup: `flutter_plugins.dart.flutter-bak-3.44.9`. If you edit SDK source, delete `flutter\bin\cache\flutter_tools.snapshot` + `.stamp` to force a rebuild.
- **Android SDK**: `C:\Users\muhdb\AppData\Local\Android\Sdk`; adb at `...\platform-tools\adb.exe`. Phone: vivo V2507A (arm64-v8a), package `com.peerm.peerm_app`.
- **Network**: phone hotspot — laptop `10.84.188.119`, phone `10.84.188.7`, subnet `10.84.188.0/24`.
- **Screencap is BLACK for Flutter on this vivo device** (Impeller/Vulkan). Rely on `adb logcat -s flutter` + code, not screenshots.

---

## Key files

| File | Role |
|---|---|
| `app/lib/services/signaling_server.dart` | Embedded pure-Dart relay server (**e:1 fix here**). Persists to `<appSupport>/peerm_server_state.json`. |
| `app/lib/services/signaling_service.dart` | WebSocket client + E2E (X25519/AES-GCM) + reconnect. Constructor generates the E2E key. |
| `app/lib/services/sync_service.dart` | Sync protocol: hello/manifest/chunks. `_onBinary` at ~line 388 was throwing the UTF-8 error. |
| `app/lib/services/relay_data_channel.dart` | Per-peer relay channel; `handleRelay`/`handleRelayBinary` decrypt on `e:1`. |
| `app/lib/services/identity_service.dart` | Persisted identity + pairings (`peerm_device_id`, `peerm_paired_device_ids` map). |
| `app/lib/controllers/app_controller.dart` | Orchestrator: host election, pairing, `_reconcileConnections` (attaches relay channels), relay routing + `_pendingRelayBinaryEnc`. |
| `app/lib/screens/devices_screen.dart` | Paired devices list (fingerprint UI was removed). |
| `server/src/index.js` | Optional Node reference server (**e:1 fix here too**). |
| `app/test/signaling_server_test.dart` | Embedded server tests (incl. new e-flag regression test). |
| `app/test/relay_data_channel_test.dart` | E2E encrypt/decrypt round-trip tests. |

---

## Gotchas / lessons learned (so the next chat doesn't re-derive them)

1. **E2E encryption was silently OFF on real devices** until `78ce13c`: `ensureE2E()` was only called from `setPeerE2E()`, but no `hello` carried a key because the key was never generated → deadlock. Fix: generate the X25519 keypair in the `SignalingService` constructor. **Any "it worked before, now broken" sync bug should first check whether E2E is actually being used and whether the receiver knows to decrypt.**
2. **The server must forward the `e:1` flag** on binary relay markers (the bug just fixed). Text and binary relay both needed it; only binary was broken.
3. **Host failover**: a device's own server never locks it out (own device always authorized); a client that gets `unauthorized` clears its stored secret and retries (the server re-binds on an empty secret).
4. **Phone identity is persisted** in SharedPreferences — if it resets, the device gets a NEW deviceId and loses its pairings. Investigate why (see regression #2).
5. **Launcher activity** is `com.ryanheise.audioservice.AudioServiceActivity` (not `.MainActivity`).
6. **`flutter analyze` + `flutter test` are the ground truth**; on-device verification relies on `adb logcat -s flutter` (screencaps are black).
7. There are temporary **sync tracing `debugPrint`s** in the code right now (`[sync] attachChannel ...`, `[sync] <- ...: hello ...`, `[e2e] deriving shared key ...`, `[sync] attaching relay channel ...`). Keep them while diagnosing; remove before release.

---

## What the new chat should do first

1. `git add -A && git commit -m "Fix relay binary marker dropping the e:1 encryption flag (broke sync when E2E turned on)"` (also covers the Node server + test + tracing).
2. Rebuild + redeploy **both** the phone debug APK and the Windows release (the phone and PC BOTH run the embedded server, so both need the fix).
3. Plug the phone in over USB, `adb logcat -s flutter`, reproduce a sync (add a song on one device), and confirm:
   - `[e2e] deriving shared key for <peer>` on both sides
   - no `Invalid UTF-8 byte` / `size mismatch: got 0` / `finalize failed`
   - files finalize (receive "Received X" or see the file appear)
4. Investigate the phone's identity reset (regression #2): check `adb shell run-as com.peerm.peerm_app cat shared_prefs/FlutterSharedPreferences.xml` for `peerm_device_id`; if it's a new id, re-pair the devices and see if the identity persists across restarts.
5. If the host keeps flapping (phone can't reach PC's `10.84.188.119:8080`), confirm both devices are on the same hotspot and the host's embedded server is actually listening (on Windows: `Get-NetTCPConnection -LocalPort 8080 -State Listen`).
