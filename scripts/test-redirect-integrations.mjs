import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createContext, runInContext } from 'node:vm';
import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
const root = 'public/integrations/redirects/';
class ValidationError extends Error {}
class InvalidEventPayload extends Error {}
class RetryError extends Error {}
const globals = {
  ValidationError,
  InvalidEventPayload,
  RetryError,
  Buffer,
  Date,
  setTimeout,
  clearTimeout,
  crypto: { createHmac, timingSafeEqual },
};
let calls = [];
const destination = createContext({
  ...globals,
  fetch: async (url, options) => {
    calls.push({ url, options });
    return { status: 201 };
  },
});
runInContext(readFileSync(root + 'segment-destination.js', 'utf8'), destination);
const lead = {
  event: 'Sign Up',
  userId: 'customer opaque',
  messageId: 'lead-one',
  context: { traits: { qg_click_id: randomUUID(), email: 'PRIVATE_EMAIL' } },
};
const settings = { apiKey: 'qg_redirect_' + 'a'.repeat(64) };
await destination.onTrack(lead, settings);
assert.equal(calls.length, 1);
assert.equal(calls[0].url, 'https://queer.guide/api/redirects/track/lead');
assert.equal(calls[0].options.redirect, 'manual');
assert.equal(calls[0].options.timeout, 10000);
assert.equal(JSON.stringify(calls).includes('PRIVATE_EMAIL'), false);
const sale = {
  event: 'Order Completed',
  userId: 'customer opaque',
  messageId: 'order-one',
  properties: { amount_decimal: '123456789012.123456', currency: 'CHF' },
};
await destination.onTrack(sale, settings);
assert.equal(JSON.parse(calls.at(-1).options.body).amount, '123456789012.123456');
await assert.rejects(
  destination.onTrack(
    { ...sale, properties: { revenue: 123456789012.123456, currency: 'CHF' } },
    settings,
  ),
  InvalidEventPayload,
);
await assert.rejects(
  destination.onTrack({ ...sale, properties: { revenue: 1.2345678, currency: 'CHF' } }, settings),
  InvalidEventPayload,
);
await assert.rejects(
  destination.onTrack({ ...lead, messageId: '' }, settings),
  InvalidEventPayload,
);
await destination.onTrack({ ...lead, properties: { qg_redirects_origin: 'redirects' } }, settings);
assert.equal(calls.length, 2);
await destination.onTrack(
  { ...sale, properties: { amount_decimal: '999999999999.999999', currency: 'CHF' } },
  settings,
);
assert.equal(JSON.parse(calls.at(-1).options.body).amount, '999999999999.999999');
destination.fetch = async () => ({ status: 503 });
await assert.rejects(destination.onTrack(lead, settings), RetryError);
destination.fetch = async () => ({ status: 302 });
await assert.rejects(destination.onTrack(lead, settings), ValidationError);
let tracks = [];
const source = createContext({
  ...globals,
  Segment: { track: async (value) => tracks.push(value) },
});
runInContext(readFileSync(root + 'segment-source.js', 'utf8'), source);
const secret = 'whsec_' + Buffer.alloc(32, 7).toString('base64');
const id = randomUUID(),
  timestamp = String(Math.floor(Date.now() / 1000));
const body = JSON.stringify({
  id,
  type: 'sale.created',
  timestamp: new Date().toISOString(),
  data: {
    customerExternalId: 'customer opaque',
    amount: '39.900001',
    currency: 'CHF',
    email: 'PRIVATE_EMAIL',
    destination: 'PRIVATE_URL',
  },
});
const signature =
  'v1,' +
  createHmac('sha256', Buffer.alloc(32, 7))
    .update(id + '.' + timestamp + '.' + body)
    .digest('base64');
const request = {
  text: () => body,
  headers: new Headers({
    'webhook-id': id,
    'webhook-timestamp': timestamp,
    'webhook-signature': signature,
  }),
};
await source.onRequest(request, { signingSecret: secret });
assert.equal(tracks[0].messageId, 'qg:' + id);
assert.equal(tracks[0].userId, 'customer opaque');
assert.equal(tracks[0].properties.amount, '39.900001');
assert.equal(JSON.stringify(tracks).includes('PRIVATE'), false);
await assert.rejects(
  source.onRequest({ ...request, text: () => body + ' ' }, { signingSecret: secret }),
  ValidationError,
);
await source.onRequest(request, {
  signingSecret: 'whsec_' + Buffer.alloc(32, 8).toString('base64'),
  previousSigningSecret: secret,
});
assert.equal(tracks.length, 2);
const template = readFileSync(root + 'google-server-conversions.tpl', 'utf8');
const sections = {};
for (const match of template.matchAll(/___([A-Z_]+)___\s*([\s\S]*?)(?=___[A-Z_]+___|$)/g))
  sections[match[1]] = match[2];
assert.deepEqual(JSON.parse(sections.INFO).containerContexts, ['SERVER']);
const permissions = JSON.parse(sections.SERVER_PERMISSIONS);
assert.equal(permissions.length, 1);
assert.equal(permissions[0].instance.param[0].value.string, 'specific');
assert.equal(permissions[0].instance.param[1].value.listItem.length, 2);
async function runTag(data, status = 201) {
  let success = 0,
    failure = 0,
    requests = [];
  const modules = {
    sendHttpRequest: async (url, options, body) => {
      requests.push({ url, options, body });
      return { statusCode: status };
    },
    JSON,
    createRegex: (text) => new RegExp(text),
    testRegex: (regex, value) => regex.test(value),
    getType: (value) => typeof value,
    makeNumber: Number,
  };
  const context = createContext({
    data: { ...data, gtmOnSuccess: () => success++, gtmOnFailure: () => failure++ },
    require: (name) => {
      if (!(name in modules)) throw new Error('Unexpected sandbox API');
      return modules[name];
    },
  });
  const result = runInContext('(function(){' + sections.SANDBOXED_JS_FOR_SERVER + '})()', context);
  await result;
  return { success, failure, requests };
}
const tag = {
  kind: 'sale',
  apiKey: settings.apiKey,
  customerExternalId: 'customer opaque',
  eventId: 'order-one',
  eventName: 'Purchase',
  amount: '39.900001',
  currency: 'CHF',
  trustedBackend: true,
  analyticsConsent: true,
};
let result = await runTag(tag);
assert.equal(result.success, 1);
assert.equal(result.failure, 0);
assert.equal(result.requests[0].options.timeout, 10000);
assert.equal(JSON.parse(result.requests[0].body).eventId, 'gtm:order-one');
for (const patch of [
  { trustedBackend: false },
  { analyticsConsent: false },
  { amount: '1.1234567' },
  { currency: 'chf' },
  { apiKey: 'private-key' },
  { clickId: 'bad-id' },
]) {
  result = await runTag({ ...tag, ...patch });
  assert.equal(result.requests.length, 0);
  assert.equal(result.failure, 1);
}
result = await runTag(tag, 302);
assert.equal(result.success, 0);
assert.equal(result.failure, 1);
console.log(
  'Segment native source/destination and Google server-template sandboxes: mapping, exact decimals, loop prevention, signature rotation/privacy, fixed URLs, permission bounds, consent/trust gates and single receipts passed. Provider account/runtime proof remains required.',
);

const store = new Map();
const cookies = [];
const dataLayer = [];
const fixtureWindow = {
  location: { href: 'https://landing.example.org/?qg_click_id=' + id, protocol: 'https:' },
  localStorage: {
    getItem: (key) => store.get(key),
    setItem: (key, value) => store.set(key, value),
    removeItem: (key) => store.delete(key),
  },
  dataLayer,
  document: {
    set cookie(value) {
      cookies.push(value);
    },
  },
};
const browser = createContext({ window: fixtureWindow, URL, Date });
runInContext(readFileSync(root + 'browser-attribution.js', 'utf8'), browser);
assert.equal(fixtureWindow.qgRedirects.getClickId(), null);
assert.equal(dataLayer.length, 0);
assert.equal(fixtureWindow.qgRedirects.setConsent(true), id);
assert.equal(dataLayer.length, 1);
assert.equal(cookies.at(-1).includes('SameSite=Lax; Secure'), true);
assert.equal(fixtureWindow.qgRedirects.setConsent(true), id);
assert.equal(dataLayer.length, 1);
fixtureWindow.qgRedirects.setConsent(false);
assert.equal(store.size, 0);
assert.equal(fixtureWindow.qgRedirects.getClickId(), null);
assert.ok(cookies.at(-1).includes('Max-Age=0'));
assert.equal(dataLayer.length, 1);
console.log(
  'Browser helper: explicit consent, canonical click IDs, host-only cookie, 30-day TTL, one attribution push per page, no conversion writes and revoke erasure passed.',
);
const timeoutDestination = createContext({
  ...globals,
  setTimeout: (callback, delay) => {
    assert.equal(delay, 10000);
    return setTimeout(callback, 5);
  },
  fetch: () => new Promise(() => {}),
});
runInContext(readFileSync(root + 'segment-destination.js', 'utf8'), timeoutDestination);
await assert.rejects(timeoutDestination.onTrack(lead, settings), RetryError);
await assert.rejects(
  source.onRequest(
    {
      ...request,
      headers: new Headers({
        'webhook-id': id,
        'webhook-timestamp': '1',
        'webhook-signature': signature,
      }),
    },
    { signingSecret: secret },
  ),
  ValidationError,
);
fixtureWindow.document = {
  set cookie(value) {
    throw new Error('Cookies disabled');
  },
};
assert.equal(fixtureWindow.qgRedirects.setConsent(true), id);
fixtureWindow.qgRedirects.clear();
assert.equal(store.size, 0);
console.log('Adapter timeout, expired signatures and cookie-disabled consent paths passed.');
