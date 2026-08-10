/**
 * Quick smoke test for the PeerM signaling server.
 * Simulates two devices: A (host) creates a pairing code, B enters it,
 * then they exchange a WebRTC signal through the server, then unpair.
 *
 * Usage: node test/smoke.js
 */
const WebSocket = require('ws');

const URL = process.env.URL || 'ws://localhost:8080';

function makeClient(name) {
  const ws = new WebSocket(URL);
  const deviceId = `${name.toLowerCase()}-${Date.now()}`;
  const inbox = [];
  ws.on('message', (raw, isBinary) => {
    if (isBinary) {
      inbox.push({ type: 'binary', binary: raw });
    } else {
      inbox.push(JSON.parse(raw.toString()));
    }
  });
  return { name, deviceId, ws, inbox };
}

function waitFor(client, type, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const timer = setInterval(() => {
      const idx = client.inbox.findIndex((m) => m.type === type);
      if (idx !== -1) {
        clearInterval(timer);
        resolve(client.inbox.splice(idx, 1)[0]);
      } else if (Date.now() - start > timeoutMs) {
        clearInterval(timer);
        reject(new Error(`Timed out waiting for '${type}' on ${client.name}. Got: ${JSON.stringify(client.inbox)}`));
      }
    }, 50);
  });
}

function open(client) {
  return new Promise((resolve, reject) => {
    client.ws.on('open', resolve);
    client.ws.on('error', reject);
  });
}

(async () => {
  const A = makeClient('Alice');
  const B = makeClient('Bob');
  await open(A);
  await open(B);

  A.ws.send(JSON.stringify({ type: 'register', deviceId: A.deviceId, deviceName: 'Alice PC' }));
  B.ws.send(JSON.stringify({ type: 'register', deviceId: B.deviceId, deviceName: 'Bob Phone' }));
  await waitFor(A, 'registered');
  await waitFor(B, 'registered');

  // A creates a pairing code
  A.ws.send(JSON.stringify({ type: 'create_pairing' }));
  const { code } = await waitFor(A, 'pairing_created');
  console.log(`[test] Alice created code: ${code}`);

  // B enters the code
  B.ws.send(JSON.stringify({ type: 'pair_with_code', code }));
  const bPaired = await waitFor(B, 'paired');
  const aPaired = await waitFor(A, 'paired');
  console.log(`[test] Bob paired with: ${bPaired.peer.deviceName}`);
  console.log(`[test] Alice paired with: ${aPaired.peer.deviceName}`);

  // Both get state listing each other (clear inbox first: registration also emits a 'state')
  A.inbox.length = 0;
  B.inbox.length = 0;
  A.ws.send(JSON.stringify({ type: 'get_state' }));
  const aState = await waitFor(A, 'state');
  B.ws.send(JSON.stringify({ type: 'get_state' }));
  const bState = await waitFor(B, 'state');
  console.log(`[test] Alice sees ${aState.pairings.length} pairing(s): ${aState.pairings.map((p) => p.deviceName).join(', ')}`);
  console.log(`[test] Bob sees ${bState.pairings.length} pairing(s): ${bState.pairings.map((p) => p.deviceName).join(', ')}`);

  // WebRTC signaling relay A -> B -> A
  A.ws.send(JSON.stringify({ type: 'signal', to: B.deviceId, data: { kind: 'offer', sdp: 'fake-offer' } }));
  const sigB = await waitFor(B, 'signal');
  console.log(`[test] Bob received relayed signal: ${JSON.stringify(sigB.data)}`);
  B.ws.send(JSON.stringify({ type: 'signal', to: A.deviceId, data: { kind: 'answer', sdp: 'fake-answer' } }));
  const sigA = await waitFor(A, 'signal');
  console.log(`[test] Alice received relayed signal: ${JSON.stringify(sigA.data)}`);

  // File-sync relay A -> B (used when WebRTC is unstable)
  A.ws.send(JSON.stringify({ type: 'relay', to: B.deviceId, data: { t: 'text', d: '{"type":"hello"}' } }));
  const relayText = await waitFor(B, 'relay');
  console.log(`[test] Bob received relayed text: ${relayText.data.d}`);
  A.ws.send(JSON.stringify({ type: 'relay', to: B.deviceId, data: { t: 'bin', d: 'aGVsbG8gd29ybGQ=' } }));
  const relayBin = await waitFor(B, 'relay');
  console.log(`[test] Bob received relayed binary (legacy base64): ${relayBin.data.d}`);

  // New binary-frame relay: marker + raw frame, then a relay_ack back to A.
  // Envelope: 0x50, idLen u16(1), songId 'a', chunkIndex u32(0), total u32(1), payload 'HI'.
  const chunk = Buffer.from([0x50, 0x00, 0x01, 0x61, 0, 0, 0, 0, 0, 0, 0, 1, 0x48, 0x49]);
  const ackPromise = waitFor(A, 'relay_ack');
  A.inbox.length = 0;
  B.inbox.length = 0;
  A.ws.send(JSON.stringify({ type: 'relay', to: B.deviceId, data: { t: 'bin' } }));
  A.ws.send(chunk);
  // The target MUST receive the {t:'bin'} marker (it pairs the raw frame with
  // its sender) followed by the raw frame.
  const relayMarker = await waitFor(B, 'relay');
  if (relayMarker.data.t !== 'bin') {
    throw new Error('target did not receive the {t:bin} marker before the frame');
  }
  const relayFrame = await waitFor(B, 'binary');
  await ackPromise;
  if (!relayFrame.binary.equals(chunk)) {
    throw new Error('relayed binary frame did not match the original chunk');
  }
  console.log(`[test] Bob got {t:bin} marker + raw frame (${relayFrame.binary.length} bytes); Alice got relay_ack`);

  // Presence: Bob disconnects, Alice should be notified
  const presencePromise = waitFor(A, 'peer_status');
  B.ws.close();
  const presence = await presencePromise;
  console.log(`[test] Alice notified Bob online=${presence.online}`);

  // Reconnect Bob, pair again via state persistence? Bob's pairing is stored on server.
  // Unpair from A
  A.ws.send(JSON.stringify({ type: 'unpair', peerId: B.deviceId }));
  const aUnpaired = await waitFor(A, 'unpaired');
  console.log(`[test] Alice unpaired ${aUnpaired.peer.deviceName}`);

  // Negative test: invalid code
  C = makeClient('Carol');
  await open(C);
  C.ws.send(JSON.stringify({ type: 'register', deviceId: C.deviceId, deviceName: 'Carol Tablet' }));
  await waitFor(C, 'registered');
  C.ws.send(JSON.stringify({ type: 'pair_with_code', code: 'ZZZZZZ' }));
  const err = await waitFor(C, 'error');
  console.log(`[test] Invalid code correctly rejected: ${err.message}`);

  A.ws.close();
  C.ws.close();
  console.log('\n[test] ALL CHECKS PASSED ✔');
  process.exit(0);
})().catch((e) => {
  console.error('\n[test] FAILED:', e.message);
  process.exit(1);
});
