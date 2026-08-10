/**
 * Rate-limit / abuse-hardening check for the PeerM signaling server.
 *
 * Verifies that the pairing-attempt rate limiter actually rejects attempts
 * past the per-window budget (brute-force pairing codes is the main attack
 * surface), and that normal flow is unaffected.
 *
 * Usage: node test/ratelimit.js  (server must be running)
 */
const WebSocket = require('ws');

const URL = process.env.URL || 'ws://localhost:8080';

function run(name, fn, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    const inbox = [];
    ws.on('message', (raw) => inbox.push(JSON.parse(raw.toString())));
    ws.on('error', (e) => reject(new Error(`${name}: connection error ${e.message}`)));
    ws.on('open', () => {
      ws.send(JSON.stringify({ type: 'register', deviceId: `ratelimit-${Date.now()}`, deviceName: name }));
    });
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error(`${name}: timed out`));
    }, timeoutMs);
    ws.on('message', (raw) => {
      const m = JSON.parse(raw.toString());
      if (m.type === 'registered') {
        fn(ws, inbox).then(
          (result) => { clearTimeout(timer); ws.close(); resolve(result); },
          (e) => { clearTimeout(timer); ws.close(); reject(e); },
        );
      }
    });
  });
}

(async () => {
  const res = await run('RateTest', (ws, inbox) => new Promise((resolve, reject) => {
    // 12 pair_with_code attempts in one window. Budget is 10, so 11+ must be
    // rejected with "Too many pairing attempts" and the first 10 must reach
    // the normal "invalid code" path.
    for (let i = 0; i < 12; i++) {
      ws.send(JSON.stringify({ type: 'pair_with_code', code: 'ZZZZZZ' }));
    }
    setTimeout(() => {
      const rateLimited = inbox.filter((x) => x.type === 'error' && /Too many/.test(x.message)).length;
      const invalid = inbox.filter((x) => x.type === 'error' && !/Too many/.test(x.message)).length;
      if (rateLimited !== 2) {
        reject(new Error(`expected 2 rate-limited rejections, got ${rateLimited}`));
        return;
      }
      if (invalid !== 10) {
        reject(new Error(`expected 10 normal invalid-code errors, got ${invalid}`));
        return;
      }
      resolve({ rateLimited, invalid });
    }, 600);
  }));

  console.log(`[test] pairing rate limiter OK (${res.rateLimited} rejected, ${res.invalid} normal invalid-code errors)`);
  console.log('\n[test] ALL CHECKS PASSED ✔');
  process.exit(0);
})().catch((e) => {
  console.error('\n[test] FAILED:', e.message);
  process.exit(1);
});
