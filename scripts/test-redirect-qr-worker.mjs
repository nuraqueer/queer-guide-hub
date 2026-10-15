// Real workerd/Wasm/Node-compat HTTP proof; no remote services or production routes.
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import assert from 'node:assert/strict';
import sharp from 'sharp';
import jsQR from 'jsqr';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const probe = createServer();
await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
const port = probe.address().port;
await new Promise((resolve) => probe.close(resolve));
const compatibilityDate = process.env.QR_TEST_COMPATIBILITY_DATE || '2026-10-13';
const child = spawn(
  process.execPath,
  [
    'node_modules/wrangler/bin/wrangler.js',
    'dev',
    '--config',
    'workers/redirect-qr/wrangler.jsonc',
    '--compatibility-date',
    compatibilityDate,
    '--ip',
    '127.0.0.1',
    '--port',
    String(port),
    '--inspector-port',
    '0',
  ],
  { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] },
);
let log = '',
  stopped = false;
child.on('exit', () => {
  stopped = true;
});
child.stdout.on('data', (chunk) => {
  log += chunk;
});
child.stderr.on('data', (chunk) => {
  log += chunk;
});
const origin = 'http://127.0.0.1:' + port;
async function get(query, init) {
  return fetch(origin + '/api/qr?' + new URLSearchParams(query), {
    ...init,
    signal: AbortSignal.timeout(20000),
  });
}
async function scanned(response, expected) {
  assert.equal(
    response.status,
    200,
    await response
      .clone()
      .text()
      .then((text) => text.slice(0, 100)),
  );
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('x-qg-qr-verified'), '1');
  const { data, info } = await sharp(new Uint8Array(await response.arrayBuffer()))
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  assert.equal(jsQR(new Uint8ClampedArray(data), info.width, info.height)?.data, expected);
}
try {
  for (let attempt = 0; attempt < 100 && !log.includes('Ready on'); attempt++) {
    if (stopped) throw new Error('Local QR Worker exited: ' + log.slice(-2500));
    await delay(100);
  }
  if (!log.includes('Ready on'))
    throw new Error('Local QR Worker did not become ready: ' + log.slice(-2500));
  const url = 'https://links.community.com/?utm_source=poster#details';
  const expected = 'https://links.community.com/?utm_source=poster&qg_qr=1#details';
  for (const format of ['png', 'jpg', 'svg'])
    await scanned(
      await get({ url, tracked: '1', format, size: '512', dots: 'joined', border: 'rounded' }),
      expected,
    );
  for (const format of ['png', 'jpeg']) {
    const logo = await sharp({
      create: { width: 64, height: 64, channels: 3, background: '#652895' },
    })
      [format]()
      .toBuffer();
    const response = await fetch(origin + '/api/qr', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        url,
        tracked: '1',
        format: 'png',
        size: '512',
        logo: 'data:image/' + format + ';base64,' + logo.toString('base64'),
      }),
      signal: AbortSignal.timeout(20000),
    });
    await scanned(response, expected);
  }
  assert.equal((await get({ url: 'https://user:secret@example.com/' })).status, 400);
  const head = await get({ url }, { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(await head.text(), '');
  const options = await get({ url }, { method: 'OPTIONS' });
  assert.equal(options.status, 204);
  assert.equal(
    (await get({ share: 'qg_qr_' + 'a'.repeat(64) })).status,
    503,
    'Missing profile configuration silently fell back',
  );
  assert.equal(
    (await get({ share: 'qg_qr_' + 'a'.repeat(64), url: 'https://evil.example/' })).status,
    400,
    'Shared payload override accepted',
  );
  let limited = false;
  for (let attempt = 0; attempt < 35; attempt++) {
    const response = await get({ url, size: '4096' });
    if (response.status === 429) {
      assert.equal(response.headers.get('retry-after'), '60');
      limited = true;
      break;
    }
    assert.equal(response.status, 400);
  }
  assert.ok(limited, 'Native request limiter did not reject excess requests');
  assert.ok(!/panic|unreachable|memory access out of bounds/i.test(log), 'Wasm runtime error');
  console.log(
    `QR Worker native HTTP/Wasm: SVG/PNG/JPG + inline PNG/JPG scan checks, HEAD/OPTIONS, validation and rate limit passed (local compatibility ${compatibilityDate}; configured 2026-10-14).`,
  );
} finally {
  child.kill('SIGTERM');
  if (!stopped)
    await Promise.race([
      new Promise((resolve) => child.once('exit', resolve)),
      delay(5000).then(() => child.kill('SIGKILL')),
    ]);
}
