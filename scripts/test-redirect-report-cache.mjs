import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';

// Execute the deployed worker itself; no copied routing predicate.
const listeners = new Map();
const origin = 'https://queer.guide';
const stores = new Map();
const cache = (name) => {
  if (!stores.has(name)) stores.set(name, new Map());
  const entries = stores.get(name);
  return {
    keys: async () => [...entries.keys()].map(url => ({ url })),
    delete: async key => entries.delete(key.url),
  };
};
for (const name of ['static-v15', 'dynamic-v15']) {
  cache(name);
  for (const path of ['/api/redirects/public-report', '/api/redirects/analytics', '/share/redirect-report/one', '/venues'])
    stores.get(name).set(origin + path, 'previously cached');
}
stores.set('trip-snapshot-fixture', new Map([[origin + '/venues', 'trip']]));
runInNewContext(await readFile(new URL('../public/sw.js', import.meta.url), 'utf8'), {
  URL, Response, location: { origin },
  self: {
    location: { hostname: 'queer.guide' },
    registration: {}, clients: { claim: async () => {} },
    addEventListener: (name, handler) => listeners.set(name, handler),
  },
  caches: { open: async name => cache(name), keys: async () => [...stores.keys()], delete: async name => stores.delete(name) },
});
for (const path of ['/api/redirects/public-report', '/api/redirects/events', '/share/redirect-report/one']) {
  let intercepted = false;
  listeners.get('fetch')({
    request: { url: origin + path, method: 'GET', mode: path.startsWith('/share/') ? 'navigate' : 'cors' },
    respondWith: () => { intercepted = true; },
  });
  assert.equal(intercepted, false, path + ' must use the network without offline fallback');
}
let activation;
listeners.get('activate')({ waitUntil: promise => { activation = promise; } });
await activation;
for (const name of ['static-v15', 'dynamic-v15'])
  assert.deepEqual([...stores.get(name).keys()], [origin + '/venues']);
assert.equal(stores.get('trip-snapshot-fixture').get(origin + '/venues'), 'trip');
console.log('Actual service worker: redirect APIs and shared reports bypass cache; old sensitive entries purged; unrelated offline data preserved.');
