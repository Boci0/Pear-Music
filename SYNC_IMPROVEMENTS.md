# Sync Improvements — Faster & More Reliable Transfer

> **Status:** Implemented (256KB chunking, sliding window flow control, partial file resume & aggressive demand completed). Future lag/performance optimization planned in §7.
> **Scope:** `app/lib/services/sync_service.dart`, `signaling_service.dart`,
> `relay_data_channel.dart`, `app_controller.dart`, plus the relay servers
> (`app/lib/services/signaling_server.dart` and `server/src/index.js`).
> **Compatibility:** Both devices must be updated together (the transfer
> protocol changes). This is already the norm — every build is deployed to
> phone + PC together.

---

## Handoff context (for the next chat — read first)

This file is the working spec for the **sync improvements** feature. It is
**not yet implemented** — the repo is on the _working_ build, and this feature
is the next task.

**Current repo state (verified 2026-08-10):**

- `main` = `f3e5b27` — "Fix mobile Add-from-link crash: keep commons-compress
  from R8 minification" (pushed to `origin/main`, release tag `Music` moved to
  it, release assets re-uploaded via `gh`).
- `flutter analyze` clean; `flutter test` **81/81** passing.
- Phone runs the arm64 **release** APK (R8-minified). Windows runs release.
- This sync feature is NOT started — start with §3.1, then §3.2, then §3.3.

**Commands:**

- Build Android release (arm64 split): `cd app; flutter build apk --release --split-per-abi`
- Build Windows: `cd app; flutter build windows --release`
- Tests: `cd app; flutter test` — analyze: `cd app; flutter analyze`
- Deploy phone: `adb install -r app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`
- Publish release after a change:
  `gh release upload Music app/build/release_pkg/PearMusic-Android-arm64.apk --clobber`
  (same for armv7; Windows zip unchanged unless Windows code changed; if the
  build's commit changes, re-point the tag with `git tag -f Music HEAD && git push --force origin Music`).

**Key files:** `sync_service.dart` (chunking/envelope/retries), `signaling_service.dart`
(relay binary flow control + E2E), `relay_data_channel.dart` (per-peer FIFO
send + marker/frame), `signaling_server.dart` (embedded server, `pendingBin`),
`server/src/index.js` (Node reference server, `pendingBin` + `RELAY_HIGH_WATER`).

**Memory:** full project history/gotchas live in `/memories/repo/peerm.md`.

---

## 1. Goal

Make peer-to-peer song sync **faster** and **more reliable**:

- **Faster:** large files (e.g. a 29 MB song) transfer in significantly less
  time.
- **More reliable:** transfers complete more often — fewer stalls, fewer
  "size mismatch" failures, less dependence on a reconnect + manifest
  exchange to self-heal.

Current reliability is already good (per-chunk ack, retries, 45s resync,
inactivity watchdog). This doc targets the **throughput** bottlenecks and a
few **robustness** gaps without regressing what works.

---

## 2. Current architecture (baseline)

The sync transport is a **relay through the signaling server** (WebSocket),
not WebRTC (WebRTC was removed — it drops on phone hotspots).

**Send path (`sync_service.dart` → `relay_data_channel.dart` → `signaling_service.dart`):**

```
SyncService._sendFile
  → RelayDataChannel.send          (per-channel FIFO queue)
    → SignalingService.sendRelayBinary(peerId, chunk)
        send marker {type:'relay', to, data:{t:'bin'[, e:1]}}   (JSON text)
        send raw binary frame  (chunk envelope, 64 KB payload)
        wait for server 'relay_ack'  ← STOP-AND-WAIT
```

**Key characteristics today:**

| Property             | Value                                                                         | Consequence                               |
| -------------------- | ----------------------------------------------------------------------------- | ----------------------------------------- |
| Chunk size           | **64 KB**                                                                     | Many round-trips; 28 B E2E overhead/chunk |
| Flow control         | **Stop-and-wait** (1 chunk in flight)                                         | Throughput ≈ chunkSize / RTT              |
| Global binary gate   | `_relayGate` — **one** binary send at a time across **all** peers             | Serializes multi-peer sync                |
| Ack matching         | Single `_pendingRelayAck` slot                                                | Correct but can't pipeline                |
| Marker/frame pairing | Server `pendingBin` = single slot per sender                                  | Pairs each frame with most-recent marker  |
| Reliability          | retries (×2), 45s resync, 120s inactivity watchdog, per-peer `_sending` guard | Good                                      |

**Bottlenecks:**

1. **Stop-and-wait per chunk.** Each 64 KB chunk costs a full sender→server→sender
   ack round-trip. On a low-latency LAN this caps out around `64KB / RTT`;
   on higher-latency links it's the dominant cost.
2. **Tiny 64 KB chunks.** With per-chunk overhead (marker + ack + 28 B E2E
   nonce/tag), smaller chunks waste bandwidth and CPU.
3. **Global serialization.** `_relayGate` serializes ALL binary transfers, even
   when two peers independently need the same or different songs.
4. **(Minor)** The 5 s ack safety timeout + resync are fine, but a dropped
   chunk mid-file still costs a full re-request of the whole song.

---

## 3. Proposed changes

### 3.1 Bigger chunks (low risk, immediate win)

Increase `SyncService.chunkSize` from `64 KB` → **256 KB** (optionally 512 KB).

- The receiver already reads the payload length from the envelope (it does
  NOT hardcode the chunk size), so no protocol break — the sender just sends
  bigger frames.
- Reduces round-trips by 4× and E2E overhead by 4× (28 B per chunk → spread
  over 256 KB).
- Stays well under the server relay cap (Node `maxPayload` 2 MB).
- **Effort:** one constant + a smoke test. Safe to do first and measure.

### 3.2 Windowed / pipelined flow control (main throughput win)

Replace stop-and-wait with a **sliding window of N chunks in flight** (e.g.
`window = 8`), paced by server acks — but keep memory bounded.

Requires tagging chunks so the receiver + server pair markers to frames and
the sender matches acks to the right chunk:

- **Marker carries a `seq`** (monotonic per peer): `{type:'relay', to, data:{t:'bin', e:1, seq: k}}`.
- **Frame body stays the chunk envelope** (unchanged), so the receiver logic
  is untouched. The `seq` is only used by the **server** to route the raw
  frame to the right peer and by the **client** to match `relay_ack`.
- **Server** replies `{type:'relay_ack', seq: k}` after relaying, so the
  sender knows exactly which chunk was acked (replaces the single-slot
  `_pendingRelayAck` with a map `seq → Completer`).
- **Sender** keeps a window counter: send up to `window` unacked chunks, then
  block only when the window is full. A lost ack is healed by the existing
  resync, and the safety timeout still applies per chunk.

This removes the global `_relayGate` serialization across peers (each peer can
run its own window) **and** pipelines chunks to a single peer — the two big
throughput wins. Memory stays bounded by `window × chunkSize`.

**Effort:** medium. Touches `signaling_service.dart` (window + seq acks),
`relay_data_channel.dart` (thread `seq`), both servers (echo `seq` in
`relay_ack`). Protocol is versioned/backward-tolerant: an old peer that
ignores `seq` still pairs each frame with its own marker (no pipelining), so
it degrades gracefully instead of breaking.

### 3.3 Reliability hardening (small, independent)

- **Resume/interrupt mid-file:** when a `file_done` never arrives and the
  inactivity watchdog aborts, today we delete the partial and re-request the
  WHOLE song. With per-chunk `index` already in the envelope, we can let the
  receiver **retain the partial file and request only the missing chunks**
  (a `request_chunks` message) instead of re-sending everything. Big win for
  large files on flaky links.
- **Per-peer concurrency:** allow a single peer's window to run even while a
  different peer's transfer is active (relaxes the global gate naturally via
  §3.2).
- Keep the existing 45s resync + retries as the safety net.

---

## 4. Files to touch

| File                                       | Change                                                 |
| ------------------------------------------ | ------------------------------------------------------ |
| `app/lib/services/sync_service.dart`       | `chunkSize` 256 KB; optional `request_chunks` resume   |
| `app/lib/services/signaling_service.dart`  | Windowed send, `seq`-keyed ack map, relax `_relayGate` |
| `app/lib/services/relay_data_channel.dart` | Carry `seq` on binary marker; ack matching             |
| `app/lib/controllers/app_controller.dart`  | Binary marker routing already seq-agnostic; verify     |
| `app/lib/services/signaling_server.dart`   | Echo `seq` in `relay_ack` (embedded server)            |
| `server/src/index.js`                      | Echo `seq` in `relay_ack` (Node reference server)      |

---

## 5. Testing plan

- **Unit (Dart):** windowed send/ack matching (frames acked out of order,
  lost ack, safety timeout); marker/frame pairing with `seq`; larger-chunk
  envelope round-trip.
- **Integration:** two fake channels sync a multi-chunk file with a `DropOnce`
  channel (chunk dropped) → still completes; concurrent transfer to two peers.
- **Server:** `relay_ack` carries correct `seq`; mixed old/new marker handling.
- **On-device:** phone↔PC over the hotspot; verify a ~29 MB song transfers
  faster than before and md5-matches (existing checksums).
- **Regression:** `flutter analyze` clean; existing sync suite still passes
  (they exercise the envelope + ack path).

---

## 6. Rollout

1. Land §3.1 (bigger chunks) alone first — trivial, measurable, low risk.
2. Land §3.2 (windowed flow control) next; verify throughput gain on-device.
3. Optionally §3.3 (resume) as a follow-up.
4. Update both devices (phone + PC) with each build — no mixed-version
   guarantee for pipelined mode.
5. Re-publish the release (`gh release upload Music … --clobber`) and re-point
   the `Music` tag if the build changes.

---

## 7. Future Performance & Lag Reduction Backlog

To eliminate UI lag/jank during aggressive multi-file transfers:

1. **Off-Main-Thread File Hashing (Isolates)**
   - Move MD5 checksum calculation (`checksum(file)`) and heavy byte slicing to Dart `compute()` background Isolates so the UI thread stays at 60 FPS while importing or hashing large files.
2. **Adaptive Resync & Progress Throttling**
   - Pause periodic `_resyncManifests()` timer ticks while active file streaming is in progress.
   - Adjust `_throttledNotify()` duration from 100 ms to 250–500 ms to reduce screen rebuild frequency during fast downloads.
3. **Dynamic Window & Pacing Control**
   - Implement dynamic window adjustment for `maxRelayWindow` (e.g. reduce window size on mobile connections with high jitter/RTT) to reduce CPU saturation and buffer bloat.
