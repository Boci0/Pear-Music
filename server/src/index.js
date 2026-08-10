/**
 * Pear Music Signaling Server
 * --------------------------
 * A lightweight WebSocket server that makes Pear Music pairing work over the
 * internet. It:
 *   1. Registers devices (deviceId + deviceName)
 *   2. Issues one-time pairing codes and creates pairings between devices
 *   3. Relays file-sync data between paired devices — small JSON control
 *      messages and raw binary chunk frames (with per-chunk acks so the sender
 *      is paced to the receiver and memory stays bounded). On networks where
 *      WebRTC P2P is unreliable (e.g. phone hotspots) this relay is the file
 *      transport; the server never stores music, it just passes it through.
 *   4. Tracks presence (who is online) and propagates un-pairing
 *
 * Music files are never stored on the server — they only pass through it.
 */

const { WebSocketServer } = require('ws');
const http = require('http');
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 8080;
const HOST = process.env.HOST || '0.0.0.0';

// Optional TLS (WSS). When PEERM_TLS_KEY + PEERM_TLS_CERT point at a cert/key
// pair, the WebSocket server serves over wss:// on PEERM_TLS_PORT (default
// 8443) and the plain HTTP port serves health + redirects to the secure
// endpoint (no more cleartext relay). Without them the server runs exactly as
// before (ws://) — the change is strictly additive.
const tlsKeyPath = process.env.PEERM_TLS_KEY;
const tlsCertPath = process.env.PEERM_TLS_CERT;
const USE_TLS = !!(tlsKeyPath && tlsCertPath);
const TLS_PORT = Number(process.env.PEERM_TLS_PORT || 8443);

// A relayed chunk is 64 KB (+ a small envelope). Cap incoming frames so a
// misbehaving client can't OOM the server, and define a high-water mark for a
// target's outbound buffer — past that the server holds acks so the sender
// backs off (end-to-end backpressure).
const MAX_PAYLOAD = 2 * 1024 * 1024; // 2 MB
const RELAY_HIGH_WATER = 4 * 1024 * 1024; // 4 MB

// ---------- In-memory state (reset on restart) ----------
const devices = new Map(); // deviceId -> { name, ws, online }
const pairingCodes = new Map(); // code -> { hostDeviceId, createdAt }
const pendingBin = new Map(); // fromDeviceId -> toDeviceId (route for next raw binary frame)

// ---------- Persistent state (survives restarts) ----------
// Pairings and device names are written to a small JSON file so a restart (or
// the deployed server cycling) does not unpair devices or wipe their shared
// songs. Path is overridable for tests/deployments via PEERM_DATA_FILE.
const DATA_FILE = process.env.PEERM_DATA_FILE || path.join(__dirname, '..', 'state.json');
const persistedPairs = new Map(); // deviceId -> Set(pairedDeviceIds)  (source of truth)
const persistedNames = new Map(); // deviceId -> last known device name
const persistedSecrets = new Map(); // deviceId -> device-auth secret (see register)

function addPersistedPair(aId, bId) {
  if (!persistedPairs.has(aId)) persistedPairs.set(aId, new Set());
  persistedPairs.get(aId).add(bId);
  if (!persistedPairs.has(bId)) persistedPairs.set(bId, new Set());
  persistedPairs.get(bId).add(aId);
}

function removePersistedPair(aId, bId) {
  const a = persistedPairs.get(aId);
  const b = persistedPairs.get(bId);
  if (a) {
    a.delete(bId);
    if (a.size === 0) persistedPairs.delete(aId);
  }
  if (b) {
    b.delete(aId);
    if (b.size === 0) persistedPairs.delete(bId);
  }
}

function saveState() {
  try {
    const pairs = [];
    const seen = new Set();
    for (const [aId, bSet] of persistedPairs) {
      for (const bId of bSet) {
        const key = aId < bId ? `${aId}|${bId}` : `${bId}|${aId}`;
        if (seen.has(key)) continue;
        seen.add(key);
        pairs.push([aId, bId]);
      }
    }
    fs.mkdirSync(path.dirname(DATA_FILE), { recursive: true });
    fs.writeFileSync(
      DATA_FILE,
      JSON.stringify(
        { pairings: pairs, names: Object.fromEntries(persistedNames), secrets: Object.fromEntries(persistedSecrets) },
        null,
        2
      )
    );
  } catch (e) {
    console.warn('[persist] failed to save state:', e.message);
  }
}

function loadState() {
  try {
    if (!fs.existsSync(DATA_FILE)) return;
    const data = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
    for (const [a, b] of data.pairings || []) {
      if (typeof a === 'string' && a && typeof b === 'string' && b) {
        addPersistedPair(a, b);
      }
    }
    for (const [id, name] of Object.entries(data.names || {})) {
      if (id) persistedNames.set(id, String(name));
    }
    for (const [id, secret] of Object.entries(data.secrets || {})) {
      if (id && typeof secret === 'string' && secret) persistedSecrets.set(id, secret);
    }
    console.log(`[persist] loaded ${persistedPairs.size} device(s) with pairings, ${persistedSecrets.size} with secrets`);
  } catch (e) {
    console.warn('[persist] failed to load state:', e.message);
  }
}

// ---------- Abuse hardening ----------
// Per-IP connection cap, per-device pairing-operation rate limit, a cap on
// non-binary (control) messages per connection, and a timeout for connections
// that never register. Binary relay frames are deliberately NOT counted in the
// control-message limit — they're already flow-controlled by relay_ack, and
// counting them would throttle legitimate fast transfers.
const MAX_CONNS_PER_IP = 8;
const REGISTER_TIMEOUT_MS = 10 * 1000;
const PAIR_OP_LIMIT = 10; // create_pairing + pair_with_code per 60s window per device
const PAIR_WINDOW_MS = 60 * 1000;
const GLOBAL_PAIR_LIMIT = 60; // pair ops per 60s across ALL devices (multi-device brute force)
const GLOBAL_PAIR_WINDOW_MS = 60 * 1000;
const CONTROL_MSG_LIMIT = 500; // control messages per 10s window per connection
const CONTROL_WINDOW_MS = 10 * 1000;
const RELAY_BYTES_BUDGET = 2 * 1024 * 1024 * 1024; // 2 GB relayed per connection (anti-abuse)
const CODE_RE = /^[A-HJ-NP-Z2-9]{6}$/; // matches CODE_ALPHABET (no I/O/0/1)

const ipCounts = new Map(); // ip -> number of open connections
const pairOps = new Map(); // deviceId -> { count, windowStart }

function getClientIp(req) {
  // Behind a TLS proxy (Render/Railway etc.) x-forwarded-for is the real IP.
  const xff = req.headers['x-forwarded-for'];
  if (typeof xff === 'string' && xff.trim()) {
    return xff.split(',')[0].trim();
  }
  return req.socket.remoteAddress || 'unknown';
}

// Returns a function that returns false once more than [limit] calls happen
// inside any [windowMs] window.
function makeWindowCounter(limit, windowMs) {
  let count = 0;
  let windowStart = Date.now();
  return () => {
    const now = Date.now();
    if (now - windowStart > windowMs) {
      windowStart = now;
      count = 0;
    }
    count++;
    return count <= limit;
  };
}

function canDoPairOp(deviceId) {
  const now = Date.now();
  let rec = pairOps.get(deviceId);
  if (!rec || now - rec.windowStart > PAIR_WINDOW_MS) {
    rec = { count: 0, windowStart: now };
    pairOps.set(deviceId, rec);
  }
  rec.count++;
  return rec.count <= PAIR_OP_LIMIT;
}

// Global pairing budget so an attacker who fabricates many deviceIds can't
// brute-force codes by multiplying per-device limits.
const allowGlobalPairOp = makeWindowCounter(GLOBAL_PAIR_LIMIT, GLOBAL_PAIR_WINDOW_MS);

// ---------- Helpers ----------
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no O/0/I/1
const CODE_LENGTH = 6;
const CODE_TTL_MS = 10 * 60 * 1000; // 10 minutes

function generateCode() {
  let code = '';
  for (let i = 0; i < CODE_LENGTH; i++) {
    code += CODE_ALPHABET[crypto.randomInt(CODE_ALPHABET.length)];
  }
  return code;
}

function getPeerSet(deviceId) {
  const d = devices.get(deviceId);
  if (!d) return new Set();
  if (!d.pairings) d.pairings = new Set();
  return d.pairings;
}

function addPair(aId, bId) {
  getPeerSet(aId).add(bId);
  getPeerSet(bId).add(aId);
  addPersistedPair(aId, bId);
  saveState();
}

function removePair(aId, bId) {
  getPeerSet(aId).delete(bId);
  getPeerSet(bId).delete(aId);
  removePersistedPair(aId, bId);
  saveState();
}

function send(ws, msg) {
  if (ws && ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

function sendBin(ws, buf) {
  if (ws && ws.readyState === ws.OPEN) {
    try {
      ws.send(buf, { binary: true });
    } catch {
      /* ignore */
    }
  }
}

// Relay a raw binary chunk from senderWs to target. Acks the sender so it can
// send the next chunk. If the target is falling behind (outbound buffer above
// the high-water mark), the ack is held until the target drains — this paces
// the sender to the target's real consumption rate and keeps the relay
// memory-bounded without ever dropping a chunk.
function relayBinary(senderWs, target, raw, seq) {
  sendBin(target.ws, raw);
  const ackMsg = { type: 'relay_ack', ...(seq !== undefined ? { seq } : {}) };
  if (target.ws.bufferedAmount > RELAY_HIGH_WATER) {
    target.ws.once('drain', () => send(senderWs, ackMsg));
  } else {
    send(senderWs, ackMsg);
  }
}

function peerInfo(id) {
  const d = devices.get(id);
  if (d) return { deviceId: id, deviceName: d.name, online: !!d.online };
  // Offline but still paired (e.g. after a restart): use the last known name
  // so the pairing survives and the client keeps its shared songs.
  const name = persistedNames.get(id);
  if (name) return { deviceId: id, deviceName: name, online: false };
  return null;
}

function sendState(ws, deviceId) {
  const pairings = [...getPeerSet(deviceId)]
    .map(peerInfo)
    .filter(Boolean)
    .map((p) => ({ deviceId: p.deviceId, deviceName: p.deviceName, online: p.online }));
  send(ws, { type: 'state', deviceId, pairings });
}

function notifyPresence(deviceId) {
  for (const peerId of getPeerSet(deviceId)) {
    const peer = devices.get(peerId);
    if (peer) send(peer.ws, { type: 'peer_status', peerId: deviceId, online: !!devices.get(deviceId)?.online });
  }
}

// ---------- HTTP(S) server (optional status page + health) ----------
// Plain HTTP serves the health check; if TLS env vars are set, WebSocket
// upgrades happen over WSS on TLS_PORT and the plain port just serves health
// + redirects to the secure endpoint (no more cleartext relay).
function handleHttp(req, res) {
  if (req.url === '/' || req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, service: 'pear-music-signaling', devices: devices.size, time: new Date().toISOString() }));
    return;
  }
  res.writeHead(404);
  res.end('Not found');
}

let server;
let wss;
if (USE_TLS) {
  server = https.createServer(
    { key: fs.readFileSync(tlsKeyPath), cert: fs.readFileSync(tlsCertPath) },
    handleHttp
  );
  http.createServer((req, res) => {
    if (req.url === '/' || req.url === '/health') return handleHttp(req, res);
    res.writeHead(301, { Location: `https://${req.headers.host || 'localhost'}/` });
    res.end('Use wss://');
  }).listen(PORT, HOST, () => {
    console.log(`Pear Music HTTP→WSS redirect listening on ${HOST}:${PORT}`);
  });
  wss = new WebSocketServer({ server, maxPayload: MAX_PAYLOAD });
} else {
  server = http.createServer(handleHttp);
  wss = new WebSocketServer({ server, maxPayload: MAX_PAYLOAD });
}

// ---------- Main message handling ----------
wss.on('connection', (ws, req) => {
  let deviceId = null;

  // WebSocket-level liveness: the server pings every 30s and terminates sockets
  // that miss two pings. Mark alive here and flip it on each pong — a
  // PER-CONNECTION handler. (The old server-level `wss.on('pong')` never fires,
  // which made the heartbeat terminate every healthy client ~30-60s after it
  // connected — the source of the constant reconnects.)
  ws.isAlive = true;
  ws.on('pong', () => {
    ws.isAlive = true;
  });

  // Per-IP connection cap.
  const ip = getClientIp(req);
  const ipCurrent = ipCounts.get(ip) || 0;
  if (ipCurrent >= MAX_CONNS_PER_IP) {
    console.warn(`[+] rejected connection from ${ip} (${ipCurrent} already open)`);
    ws.close(4002, 'too many connections');
    return;
  }
  ipCounts.set(ip, ipCurrent + 1);
  console.log(`[+] client connected (${wss.clients.size} online, ip=${ip})`);

  // Control-message rate limiter (binary frames excluded, see note above).
  const allowControl = makeWindowCounter(CONTROL_MSG_LIMIT, CONTROL_WINDOW_MS);

  // Close connections that never register (bots occupying a slot).
  const registerTimer = setTimeout(() => {
    if (!deviceId) ws.close(4004, 'register timeout');
  }, REGISTER_TIMEOUT_MS);

  ws.on('message', (raw, isBinary) => {
    if (!isBinary && !allowControl()) {
      console.warn(`[rate] ${devices.get(deviceId)?.name || ip} — control message flood`);
      ws.close(4003, 'rate limited');
      return;
    }
    // Raw binary frame: the body of a relayed chunk. Its route was announced by
    // the preceding {t:'bin'} relay marker from this device, so forward it
    // unchanged to that peer (no base64 round-trip → ~33% less bandwidth).
    if (isBinary) {
      if (deviceId) {
        // Per-connection relay budget so a paired-but-abusive peer can't push
        // unbounded data through the relay (2 GB is far above any legit sync).
        ws.relayedBytes = (ws.relayedBytes || 0) + raw.length;
        if (ws.relayedBytes > RELAY_BYTES_BUDGET) {
          console.warn(`[relay] ${devices.get(deviceId)?.name} exceeded relay byte budget; closing`);
          ws.close(4003, 'relay budget exceeded');
          return;
        }
        const route = pendingBin.get(deviceId);
        if (route !== undefined) {
          pendingBin.delete(deviceId);
          const targetId = typeof route === 'string' ? route : route.to;
          const seq = typeof route === 'object' ? route.seq : undefined;
          if (getPeerSet(deviceId).has(targetId)) {
            const target = devices.get(targetId);
            if (target) relayBinary(ws, target, raw, seq);
          }
        }
      }
      return;
    }
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }

    switch (msg.type) {
      // ---- Register / re-register ----
      case 'register': {
        const id = String(msg.deviceId || '').trim();
        const name = String(msg.deviceName || 'Unnamed device').trim().slice(0, 40);
        if (!id) {
          send(ws, { type: 'error', message: 'deviceId is required' });
          return;
        }
        // Device-authentication secret. Once a deviceId has a bound secret:
        //   - a matching secret is accepted;
        //   - a WRONG secret is rejected (stops secret-guessing / a stolen
        //     secret from another device);
        //   - an EMPTY secret is accepted and re-binds a fresh one, so an
        //     upgraded client (or a reinstall) is never locked out.
        // The real impersonation defense is WSS (wire encryption); this secret
        // adds defense-in-depth without ever breaking the upgrade path.
        const givenSecret = String(msg.secret || '');
        if (persistedSecrets.has(id)) {
          if (givenSecret && givenSecret !== persistedSecrets.get(id)) {
            console.warn(`[auth] rejected register for ${id} (mismatched secret)`);
            send(ws, { type: 'error', message: 'unauthorized' });
            ws.close(4001, 'unauthorized');
            return;
          }
          if (!givenSecret) {
            persistedSecrets.set(id, crypto.randomBytes(24).toString('hex'));
            saveState();
          }
        } else {
          persistedSecrets.set(id, givenSecret || crypto.randomBytes(24).toString('hex'));
          saveState();
        }
        // If this device was connected elsewhere, kick the old socket.
        const existing = devices.get(id);
        if (existing && existing.ws !== ws) {
          try { existing.ws.close(4001, 'replaced'); } catch { /* ignore */ }
        }
        deviceId = id;
        clearTimeout(registerTimer);
        // Seed pairings from persistence so a restart doesn't unpair devices.
        const pairings = new Set(existing?.pairings || []);
        const persisted = persistedPairs.get(id);
        if (persisted) {
          for (const pid of persisted) pairings.add(pid);
        }
        devices.set(id, { name, ws, online: true, pairings });
        // Remember the name so offline peers still show it after a restart.
        if (persistedNames.get(id) !== name) {
          persistedNames.set(id, name);
          saveState();
        }
        // Drop pairings to peers that are neither registered nor persisted
        // (truly stale/foreign deviceIds). Persisted pairings to offline peers
        // are kept so they survive restarts.
        for (const peerId of [...pairings]) {
          if (!devices.has(peerId) && !persistedPairs.get(id)?.has(peerId)) {
            pairings.delete(peerId);
          }
        }
        send(ws, { type: 'registered', deviceId: id, secret: persistedSecrets.get(id) });
        sendState(ws, id);
        notifyPresence(id);
        console.log(`[register] ${name} (${id})`);
        break;
      }

      // ---- Host creates a pairing code ----
      case 'create_pairing': {
        if (!deviceId) return;
        if (!canDoPairOp(deviceId)) {
          send(ws, { type: 'error', message: 'Too many pairing operations. Please wait a minute and try again.' });
          return;
        }
        // Invalidate any previous pending code for this device.
        for (const [code, info] of pairingCodes) {
          if (info.hostDeviceId === deviceId) pairingCodes.delete(code);
        }
        const code = generateCode();
        pairingCodes.set(code, { hostDeviceId: deviceId, createdAt: Date.now() });
        send(ws, { type: 'pairing_created', code, expiresIn: CODE_TTL_MS / 1000 });
        console.log(`[code] ${devices.get(deviceId)?.name} created pairing code ${code}`);
        break;
      }

      // ---- Peer enters a code to pair ----
      case 'pair_with_code': {
        if (!deviceId) return;
        if (!canDoPairOp(deviceId)) {
          send(ws, { type: 'error', message: 'Too many pairing attempts. Please wait a minute and try again.' });
          return;
        }
        if (!allowGlobalPairOp()) {
          send(ws, { type: 'error', message: 'Too many pairing attempts. Please wait a minute and try again.' });
          return;
        }
        const code = String(msg.code || '').trim().toUpperCase();
        // Reject malformed codes fast (defense in depth).
        if (!CODE_RE.test(code)) {
          send(ws, { type: 'error', message: 'Invalid or expired pairing code.' });
          return;
        }
        const pending = pairingCodes.get(code);
        if (!pending) {
          send(ws, { type: 'error', message: 'Invalid or expired pairing code.' });
          return;
        }
        if (pending.hostDeviceId === deviceId) {
          send(ws, { type: 'error', message: 'You cannot pair with yourself.' });
          return;
        }
        pairingCodes.delete(code); // single use
        addPair(deviceId, pending.hostDeviceId);
        const me = peerInfo(deviceId);
        const host = peerInfo(pending.hostDeviceId);
        send(ws, { type: 'paired', peer: host });
        send(devices.get(pending.hostDeviceId)?.ws, { type: 'paired', peer: me });
        notifyPresence(deviceId);
        notifyPresence(pending.hostDeviceId);
        console.log(`[pair] ${me?.deviceName} <-> ${host?.deviceName}`);
        break;
      }

      // ---- Relay WebRTC signaling between paired devices ----
      case 'signal': {
        if (!deviceId) return;
        const to = String(msg.to || '');
        if (!getPeerSet(deviceId).has(to)) return; // must be paired
        const target = devices.get(to);
        if (!target) return;
        send(target.ws, { type: 'signal', from: deviceId, data: msg.data });
        break;
      }

      // ---- Relay file-sync data between paired devices ----
      // WebRTC can be unstable on some networks (e.g. phone hotspots), so
      // Pear Music can fall back to relaying the file stream through this server.
      // Binary chunks are sent as a raw frame right after this marker.
      case 'relay': {
        if (!deviceId) return;
        const to = String(msg.to || '');
        if (!getPeerSet(deviceId).has(to)) return; // must be paired
        const target = devices.get(to);
        if (!target) return;
        const t = msg.data?.t;
        if (t === 'bin') {
          if (typeof msg.data?.d === 'string') {
            // Legacy: a base64 chunk inside the JSON envelope.
            send(target.ws, { type: 'relay', from: deviceId, data: msg.data });
          } else {
            // New: the chunk body follows as a raw binary frame. First tell
            // the target which peer the frame is from (the app needs that to
            // route the bytes), then remember the route so the frame handler
            // can forward them unchanged. PRESERVE the `e:1` encryption flag —
            // the receiver must know to decrypt the frame (dropping it broke
            // sync once E2E encryption actually turned on).
            const seq = msg.data?.seq;
            send(target.ws, {
              type: 'relay',
              from: deviceId,
              data: {
                t: 'bin',
                ...(msg.data?.e === 1 ? { e: 1 } : {}),
                ...(seq !== undefined ? { seq } : {}),
              },
            });
            pendingBin.set(deviceId, { to, seq });
          }
        } else {
          send(target.ws, { type: 'relay', from: deviceId, data: msg.data });
          if (t === 'text') {
            console.log(
              `[relay] ${devices.get(deviceId)?.name} -> ${target.name} (text)`
            );
          }
        }
        break;
      }

      // ---- Unpair ----
      case 'unpair': {
        if (!deviceId) return;
        const peerId = String(msg.peerId || '');
        if (!getPeerSet(deviceId).has(peerId)) return;
        removePair(deviceId, peerId);
        const peer = peerInfo(peerId);
        send(ws, { type: 'unpaired', peer: peer ? { deviceId: peer.deviceId, deviceName: peer.deviceName } : { deviceId: peerId } });
        send(devices.get(peerId)?.ws, {
          type: 'unpaired',
          peer: peerInfo(deviceId) ? { deviceId, deviceName: devices.get(deviceId).name } : { deviceId },
        });
        console.log(`[unpair] ${devices.get(deviceId)?.name} removed ${peer?.deviceName ?? peerId}`);
        break;
      }

      // ---- Ask for current state (e.g. after reconnect) ----
      case 'get_state': {
        if (!deviceId) return;
        sendState(ws, deviceId);
        break;
      }

      // ---- Client heartbeat ----
      // Clients ping periodically so they can detect a dead/half-open server
      // connection (e.g. after a server restart) instead of sitting in a fake
      // "connected" state. Reply with a pong.
      case 'ping': {
        send(ws, { type: 'pong' });
        break;
      }

      default:
        send(ws, { type: 'error', message: `Unknown message type: ${msg.type}` });
    }
  });

  ws.on('close', () => {
    clearTimeout(registerTimer);
    const remaining = (ipCounts.get(ip) || 1) - 1;
    if (remaining <= 0) ipCounts.delete(ip);
    else ipCounts.set(ip, remaining);
    if (deviceId && devices.get(deviceId)?.ws === ws) {
      devices.get(deviceId).online = false;
      pendingBin.delete(deviceId); // drop any half-sent relay route
      notifyPresence(deviceId);
      console.log(`[-] ${devices.get(deviceId)?.name} disconnected`);
    }
  });

  ws.on('error', () => { /* ignore */ });
});

// Heartbeat: drop dead connections every 30s. A socket that misses two pings
// (isAlive still false at the next tick) is terminated; healthy sockets flip
// isAlive back to true in their per-connection 'pong' handler above.
const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (ws.isAlive === false) {
      ws.terminate();
      continue;
    }
    ws.isAlive = false;
    ws.ping();
  }
}, 30000);
wss.on('close', () => clearInterval(heartbeat));

// Expire old pairing codes.
setInterval(() => {
  const now = Date.now();
  for (const [code, info] of pairingCodes) {
    if (now - info.createdAt > CODE_TTL_MS) pairingCodes.delete(code);
  }
}, 60000);

// Load persisted pairings/names before serving.
loadState();

const listenPort = USE_TLS ? TLS_PORT : PORT;
const scheme = USE_TLS ? 'wss' : 'ws';
server.listen(listenPort, HOST, () => {
  console.log(`Pear Music signaling server listening on ${HOST}:${listenPort} (${scheme})`);
  console.log(`  ${scheme}://localhost:${listenPort}`);
  if (USE_TLS) console.log(`  plain HTTP→WSS redirect on ${HOST}:${PORT}`);
  console.log(`  persistent state: ${DATA_FILE}`);
});
