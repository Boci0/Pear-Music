/**
 * Security hardening check for the PeerM signaling server.
 *
 * Verifies:
 *   1. A fresh deviceId gets a device-auth secret issued on first register.
 *   2. Re-registering with the WRONG secret is rejected ('unauthorized').
 *   3. Re-registering with the CORRECT secret is accepted.
 *   4. Malformed pairing codes are rejected fast (defense in depth).
 *
 * Usage: node test/security.js   (server must be running)
 */
const WebSocket = require('ws');

const URL = process.env.URL || 'ws://localhost:8080';

function regOnce(deviceId, secret) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    const inbox = [];
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error(`register timeout; inbox=${JSON.stringify(inbox)}`));
    }, 5000);
    ws.on('message', (raw) => {
      const m = JSON.parse(raw.toString());
      inbox.push(m);
      if (m.type === 'registered' || (m.type === 'error' && m.message === 'unauthorized')) {
        clearTimeout(timer);
        ws.close();
        resolve(m);
      }
    });
    ws.on('open', () =>
      ws.send(JSON.stringify({ type: 'register', deviceId, deviceName: 'SecTest', ...(secret ? { secret } : {}) }))
    );
    ws.on('error', (e) => {
      clearTimeout(timer);
      reject(e);
    });
  });
}

function makeClient() {
  const ws = new WebSocket(URL);
  const inbox = [];
  const ready = new Promise((resolve, reject) => {
    ws.on('open', resolve);
    ws.on('error', reject);
  });
  ws.on('message', (raw) => inbox.push(JSON.parse(raw.toString())));
  return { ws, inbox, ready };
}

function waitMsg(c, type, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const t = setInterval(() => {
      const i = c.inbox.findIndex((m) => m.type === type);
      if (i !== -1) {
        clearInterval(t);
        resolve(c.inbox.splice(i, 1)[0]);
      } else if (Date.now() - start > timeoutMs) {
        clearInterval(t);
        reject(new Error(`timeout waiting for '${type}'; inbox=${JSON.stringify(c.inbox)}`));
      }
    }, 50);
  });
}

(async () => {
  const base = `sec-${Date.now()}`;
  const id = `${base}-a`;

  // 1) First contact issues a secret.
  const reg1 = await regOnce(id);
  if (!reg1.secret || reg1.secret.length < 16) {
    throw new Error('expected a device-auth secret to be issued on first register');
  }
  console.log(`[test] secret issued on first register: ${reg1.secret.slice(0, 10)}…`);

  // 2) Wrong secret is rejected.
  const bad = await regOnce(id, 'deadbeefdeadbeef');
  if (bad.message !== 'unauthorized') {
    throw new Error(`expected 'unauthorized' for wrong secret, got: ${JSON.stringify(bad)}`);
  }
  console.log('[test] wrong secret rejected ✔');

  // 3) Correct secret is accepted.
  const reg2 = await regOnce(id, reg1.secret);
  if (reg2.type !== 'registered') {
    throw new Error(`expected register with correct secret to succeed, got: ${JSON.stringify(reg2)}`);
  }
  console.log('[test] correct secret accepted ✔');

  // 4) Malformed codes are rejected immediately (no internal lookup).
  const c = makeClient();
  await c.ready;
  c.ws.send(JSON.stringify({ type: 'register', deviceId: `${base}-c`, deviceName: 'SecClient' }));
  await waitMsg(c, 'registered');
  c.ws.send(JSON.stringify({ type: 'pair_with_code', code: '!!!!!!' }));
  const malformed = await waitMsg(c, 'error');
  if (!/Invalid or expired/.test(malformed.message)) {
    throw new Error(`expected malformed code rejection, got: ${JSON.stringify(malformed)}`);
  }
  console.log('[test] malformed code rejected fast ✔');

  c.ws.close();
  console.log('\n[test] ALL CHECKS PASSED ✔');
  process.exit(0);
})().catch((e) => {
  console.error('\n[test] FAILED:', e.message);
  process.exit(1);
});
