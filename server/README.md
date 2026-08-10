# PeerM Signaling Server

A tiny WebSocket server that makes PeerM pairing work over the internet.

It does **not** transfer music. It only:

1. registers devices (`deviceId` + `deviceName`),
2. issues one-time pairing codes and creates pairings,
3. relays WebRTC signaling (SDP offer/answer + ICE) between paired devices,
4. tracks presence and propagates unpairing.

Music files flow device-to-device over WebRTC, never through this server.

## Run locally

```bash
npm install
npm start          # ws://0.0.0.0:8080
```

`PORT` and `HOST` env vars are respected.

## Deploy for internet pairing

Any Node 18+ host works. The server is stateless, so you can run one instance
for all your devices. A few options:

**Render (free)**

1. New → Web Service → point at this `server/` folder.
2. Build: `npm install` · Start: `npm start`.
3. It gives you `https://<name>.onrender.com` — use `wss://<name>.onrender.com`
   in the app's Settings (the host handles TLS termination for `wss://`).

**Railway / Fly.io / VPS** — same idea: run `node src/index.js` and expose port 8080.

**Home network (no public hosting)**

- Run it on your PC and use `ws://<pc-lan-ip>:8080` from your phone (same Wi-Fi).
- Open port 8080 in the router firewall if you want to reach it from outside.

## Security / TLS (WSS)

By default the server runs plain `ws://`. For anything beyond a trusted LAN,
run it with a TLS cert so the signaling **and the relayed file stream** are
encrypted in transit (this also stops an eavesdropper from sniffing pairing
codes / device IDs):

```bash
PEERM_TLS_KEY=/path/key.pem PEERM_TLS_CERT=/path/cert.pem npm start
# WebSocket now serves wss:// on :8443 (override with PEERM_TLS_PORT);
# the plain :8080 port serves /health and redirects to https.
```

Then point the app's Settings at `wss://<host>:8443` (or `wss://<host>` if a
reverse proxy like Caddy/Render terminates TLS for you — the server already
trusts `x-forwarded-for`).

Other built-in hardening (always on): device-auth secrets issued at first
registration (a mismatched secret is rejected; empty re-binds so upgrades are
seamless), per-device + global pairing rate limits, malformed-code rejection,
2 MB max frame size, per-IP connection cap, and a per-connection relay byte
budget.

## Protocol (JSON over WebSocket)

Client → server:

| Message                                       | Purpose                          |
| --------------------------------------------- | -------------------------------- |
| `{"type":"register","deviceId","deviceName"}` | identify this device             |
| `{"type":"create_pairing"}`                   | host requests a new pairing code |
| `{"type":"pair_with_code","code"}`            | peer enters a code to pair       |
| `{"type":"signal","to","data"}`               | relay WebRTC signal to a peer    |
| `{"type":"unpair","peerId"}`                  | break a pairing                  |
| `{"type":"get_state"}`                        | fetch current pairings           |

Server → client:

| Message                                    | Purpose                            |
| ------------------------------------------ | ---------------------------------- |
| `{"type":"registered","deviceId"}`         | registration ok                    |
| `{"type":"state","pairings":[...]}`        | current paired devices             |
| `{"type":"pairing_created","code"}`        | a new code for the host            |
| `{"type":"paired","peer"}`                 | a pairing was created (both sides) |
| `{"type":"unpaired","peer"}`               | a pairing was removed (both sides) |
| `{"type":"signal","from","data"}`          | relayed WebRTC signal              |
| `{"type":"peer_status","peerId","online"}` | presence change                    |
| `{"type":"error","message"}`               | something went wrong               |

Pairing codes are 6 characters (no `0/O/1/I`), single-use, expire after 10 min.

## Smoke test

With the server running on `:8080`:

```bash
node test/smoke.js
```

Simulates two devices (register → create code → pair → signal relay → presence
→ unpair → invalid code) and prints `ALL CHECKS PASSED`.
