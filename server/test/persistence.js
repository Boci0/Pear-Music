/**
 * Persistence check: pairings (and device names) must survive a server restart.
 *
 * Starts the server on a throwaway port with a throwaway state file, pairs two
 * devices, restarts the server, then verifies the pairing is still there — even
 * though the peer never re-registered — and that an unpair persists too.
 *
 * Usage: node test/persistence.js
 */
const { spawn } = require('child_process');
const WebSocket = require('ws');
const os = require('os');
const path = require('path');

const SCRIPT = path.join(__dirname, '..', 'src', 'index.js');
const PORT = Number(process.env.TEST_PORT || 8091);
const URL = `ws://localhost:${PORT}`;
const DATA_FILE = path.join(os.tmpdir(), `peerm-persist-${Date.now()}.json`);

function startServer() {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [SCRIPT], {
      env: { ...process.env, PORT: String(PORT), PEERM_DATA_FILE: DATA_FILE },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let log = '';
    child.stdout.on('data', (d) => {
      log += d;
      if (String(d).includes('listening')) {
        clearTimeout(timer);
        resolve(child);
      }
    });
    child.stderr.on('data', (d) => {
      log += d;
    });
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`server did not start:\n${log}`));
    }, 8000);
  });
}

function stopServer(child) {
  return new Promise((resolve) => {
    if (child.exitCode !== null) return resolve();
    const killer = setTimeout(() => child.kill('SIGKILL'), 2000);
    child.on('exit', () => {
      clearTimeout(killer);
      resolve();
    });
    child.kill('SIGTERM');
  });
}

function makeClient(name) {
  const ws = new WebSocket(URL);
  const deviceId = `${name.toLowerCase()}-persist`;
  const inbox = [];
  ws.on('message', (raw) => inbox.push(JSON.parse(raw.toString())));
  return { name, deviceId, ws, inbox };
}

function open(client) {
  return new Promise((resolve, reject) => {
    client.ws.on('open', resolve);
    client.ws.on('error', reject);
  });
}

function waitFor(client, type, timeoutMs = 6000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const timer = setInterval(() => {
      const idx = client.inbox.findIndex((m) => m.type === type);
      if (idx !== -1) {
        clearInterval(timer);
        resolve(client.inbox.splice(idx, 1)[0]);
      } else if (Date.now() - start > timeoutMs) {
        clearInterval(timer);
        reject(
          new Error(
            `Timed out waiting for '${type}' on ${client.name}. Got: ${JSON.stringify(client.inbox)}`
          )
        );
      }
    }, 50);
  });
}

(async () => {
  // ---- Generation 1: pair two devices ----
  let server = await startServer();
  const A = makeClient('Alice');
  const B = makeClient('Bob');
  await open(A);
  await open(B);
  A.ws.send(
    JSON.stringify({ type: 'register', deviceId: A.deviceId, deviceName: 'Alice PC' })
  );
  B.ws.send(
    JSON.stringify({ type: 'register', deviceId: B.deviceId, deviceName: 'Bob Phone' })
  );
  await waitFor(A, 'registered');
  await waitFor(B, 'registered');
  A.ws.send(JSON.stringify({ type: 'create_pairing' }));
  const { code } = await waitFor(A, 'pairing_created');
  B.ws.send(JSON.stringify({ type: 'pair_with_code', code }));
  await waitFor(B, 'paired');
  await waitFor(A, 'paired');
  A.ws.close();
  B.ws.close();
  await stopServer(server);
  console.log('[test] gen1: Alice and Bob paired');

  // ---- Generation 2: restart; only Alice reconnects ----
  server = await startServer();
  const A2 = makeClient('Alice');
  await open(A2);
  A2.ws.send(
    JSON.stringify({ type: 'register', deviceId: A2.deviceId, deviceName: 'Alice PC v2' })
  );
  await waitFor(A2, 'registered');
  const state = await waitFor(A2, 'state');
  const bob = state.pairings.find((p) => p.deviceId === B.deviceId);
  if (!bob) throw new Error('pairing to offline peer was lost after restart');
  if (bob.deviceName !== 'Bob Phone') {
    throw new Error(`persisted name lost: ${bob.deviceName}`);
  }
  if (bob.online !== false) {
    throw new Error(`offline peer should be online:false, got ${bob.online}`);
  }
  console.log('[test] gen2: pairing survived restart; offline peer listed with persisted name');
  A2.ws.close();
  await stopServer(server);

  // ---- Generation 3: unpair while the peer is offline must persist ----
  server = await startServer();
  const A3 = makeClient('Alice');
  await open(A3);
  A3.ws.send(
    JSON.stringify({ type: 'register', deviceId: A3.deviceId, deviceName: 'Alice PC v3' })
  );
  await waitFor(A3, 'registered');
  A3.inbox.length = 0;
  A3.ws.send(JSON.stringify({ type: 'unpair', peerId: B.deviceId }));
  await waitFor(A3, 'unpaired');
  A3.inbox.length = 0;
  A3.ws.send(JSON.stringify({ type: 'get_state' }));
  const state2 = await waitFor(A3, 'state');
  if (state2.pairings.some((p) => p.deviceId === B.deviceId)) {
    throw new Error('pairing was not removed after unpair');
  }
  console.log('[test] gen3: unpair persisted (offline peer removed)');
  A3.ws.close();
  await stopServer(server);

  console.log('\n[test] ALL CHECKS PASSED ✔');
  process.exit(0);
})().catch((e) => {
  console.error('\n[test] FAILED:', e.message);
  process.exit(1);
});
