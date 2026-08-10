/**
 * Heartbeat verification: a healthy WebSocket must NOT be terminated by the
 * server's 30s liveness heartbeat.
 *
 * The old code attached the 'pong' handler to the WebSocketServer (which never
 * fires), so every healthy client was killed ~30-60s after connecting. This
 * test holds a connection open for > 2 heartbeat cycles and asserts it is
 * still OPEN at the end.
 *
 * Usage: node test/heartbeat.js   (server must be running)
 *        HOLD_MS overrides the hold time (default 70s).
 */
const WebSocket = require('ws');

const URL = process.env.URL || 'ws://localhost:8080';
const HOLD_MS = Number(process.env.HOLD_MS || 70000); // > 2 heartbeat cycles (30s each)

(async () => {
  const ws = new WebSocket(URL);
  let registered = false;

  await new Promise((resolve, reject) => {
    ws.on('open', resolve);
    ws.on('error', reject);
  });
  ws.on('message', (raw) => {
    const m = JSON.parse(raw.toString());
    if (m.type === 'registered') registered = true;
  });
  ws.send(
    JSON.stringify({ type: 'register', deviceId: `heartbeat-${Date.now()}`, deviceName: 'HeartbeatTest' })
  );

  // Wait until registered (the socket is definitely up and heartbeating).
  await new Promise((resolve) => {
    const t = setInterval(() => {
      if (registered) {
        clearInterval(t);
        resolve();
      }
    }, 50);
    setTimeout(() => resolve(), 3000); // safety
  });

  console.log(`[test] connected; holding ${HOLD_MS / 1000}s (past 2 heartbeat cycles)...`);
  await new Promise((resolve) => setTimeout(resolve, HOLD_MS));

  if (ws.readyState === WebSocket.OPEN) {
    console.log(`[test] socket still OPEN after ${HOLD_MS / 1000}s — heartbeat keeps healthy clients ✔`);
    ws.close();
    process.exit(0);
  } else {
    console.error(
      `[test] FAILED: socket state ${ws.readyState} (OPEN=1) — the heartbeat terminated a healthy client`
    );
    process.exit(1);
  }
})().catch((e) => {
  console.error('\n[test] FAILED:', e.message);
  process.exit(1);
});
