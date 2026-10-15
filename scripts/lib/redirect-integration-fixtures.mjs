import { readFileSync } from 'node:fs';
import { createContext, runInContext } from 'node:vm';
import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import assert from 'node:assert/strict';
export async function verifyRedirectIntegrationHttp(db, base, actor) {
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
  const link = (
    await db.query(
      "INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','native-integration-fixture','https://example.org/integration') RETURNING id",
    )
  ).rows[0].id;
  await db.query(
    `INSERT INTO public.redirect_link_policies(redirect_id,policy) VALUES($1,'{"track_conversions":true}'::jsonb)`,
    [link],
  );
  const click = (
    await db.query(
      "SELECT public.record_redirect_visit($1,'/go/native-integration-fixture',NULL,NULL,'Fixture','CH',NULL,302,NULL,'https://example.org/integration') AS id",
      [link],
    )
  ).rows[0].id;
  const key = 'qg_redirect_' + randomBytes(32).toString('hex');
  const principal = (
    await db.query(
      "INSERT INTO public.redirect_api_tokens(name,token_hash,prefix,scopes,redirect_ids,created_by,expires_at) VALUES('Native integration fixture',$1,'fixture',ARRAY['conversions:write'],ARRAY[$2]::uuid[],$3,now()+interval '1 day') RETURNING id",
      [createHash('sha256').update(key).digest('hex'), link, actor],
    )
  ).rows[0].id;
  const secret = 'whsec_' + randomBytes(32).toString('base64');
  const sub = (
    await db.query(
      "SELECT public.redirect_webhook_resource('create',$1,NULL,NULL,$2::jsonb,$3) AS value",
      [
        actor,
        JSON.stringify({
          name: 'Segment source fixture',
          url: 'https://receiver.example.org/segment',
          eventTypes: ['lead.created', 'sale.created'],
          linkIds: [link],
          includeCustomerId: true,
        }),
        secret,
      ],
    )
  ).rows[0].value;
  const calls = [];
  const send = async (url, options) => {
    const target = new URL(url);
    assert.equal(target.origin, 'https://queer.guide');
    assert.ok(['/api/redirects/track/lead', '/api/redirects/track/sale'].includes(target.pathname));
    calls.push({ url, options });
    return fetch(base + target.pathname.slice('/api/redirects'.length), {
      ...options,
      signal: AbortSignal.timeout(10000),
    });
  };
  const destination = createContext({ ...globals, fetch: send });
  runInContext(
    readFileSync('public/integrations/redirects/segment-destination.js', 'utf8'),
    destination,
  );
  const lead = {
    event: 'Sign Up',
    userId: 'native integration customer',
    messageId: 'native-integration-lead',
    properties: { qg_click_id: click },
  };
  await destination.onTrack(lead, { apiKey: key });
  await destination.onTrack(lead, { apiKey: key });
  await destination.onTrack(
    {
      event: 'Order Completed',
      userId: lead.userId,
      messageId: 'native-integration-sale',
      properties: { amount_decimal: '49.123456', currency: 'CHF' },
    },
    { apiKey: key },
  );
  let events = (
    await db.query(
      'SELECT provider_event_id AS event_id,amount::text FROM public.redirect_link_conversions WHERE customer_key=$1 ORDER BY kind',
      [lead.userId],
    )
  ).rows;
  assert.equal(events.length, 2);
  assert.equal(
    events.find((row) => row.event_id === 'segment:native-integration-sale').amount,
    '49.123456',
  );
  const template = readFileSync(
    'public/integrations/redirects/google-server-conversions.tpl',
    'utf8',
  )
    .split('___SANDBOXED_JS_FOR_SERVER___')[1]
    .split('___SERVER_PERMISSIONS___')[0];
  let success = 0,
    failure = 0;
  const modules = {
    JSON,
    createRegex: (text) => new RegExp(text),
    testRegex: (regex, value) => regex.test(value),
    getType: (value) => typeof value,
    makeNumber: Number,
    sendHttpRequest: async (url, options, body) => {
      const response = await send(url, { ...options, body, redirect: 'manual' });
      return { statusCode: response.status };
    },
  };
  const data = {
    kind: 'sale',
    apiKey: key,
    customerExternalId: lead.userId,
    eventId: 'native-gtm-order',
    eventName: 'Ticket purchase',
    amount: '39.900001',
    currency: 'CHF',
    trustedBackend: true,
    analyticsConsent: true,
    gtmOnSuccess: () => success++,
    gtmOnFailure: () => failure++,
  };
  const google = createContext({ data, require: (name) => modules[name] });
  await runInContext('(function(){' + template + '})()', google);
  assert.equal(success, 1);
  assert.equal(failure, 0);
  data.analyticsConsent = false;
  await runInContext('(function(){' + template + '})()', google);
  assert.equal(failure, 1);
  assert.equal(calls.length, 4);
  let tracks = [];
  const source = createContext({
    ...globals,
    Segment: { track: async (value) => tracks.push(value) },
  });
  runInContext(readFileSync('public/integrations/redirects/segment-source.js', 'utf8'), source);
  const deliveries = (
    await db.query(
      'SELECT body,event_id FROM public.redirect_webhook_deliveries WHERE webhook_id=$1 ORDER BY sequence',
      [sub.id],
    )
  ).rows;
  assert.equal(deliveries.length, 3);
  for (const delivery of deliveries) {
    const timestamp = String(Math.floor(Date.now() / 1000));
    const signature =
      'v1,' +
      createHmac('sha256', Buffer.from(secret.slice(6), 'base64'))
        .update(delivery.event_id + '.' + timestamp + '.' + delivery.body)
        .digest('base64');
    await source.onRequest(
      {
        text: () => delivery.body,
        headers: new Headers({
          'webhook-id': delivery.event_id,
          'webhook-timestamp': timestamp,
          'webhook-signature': signature,
        }),
      },
      { signingSecret: secret },
    );
  }
  assert.equal(tracks.length, 3);
  assert.equal(tracks.find((row) => row.properties.amount === '39.900001').userId, lead.userId);
  const before = calls.length;
  for (const event of tracks)
    await destination.onTrack(
      { ...event, event: 'Order Completed', userId: lead.userId },
      { apiKey: key },
    );
  assert.equal(calls.length, before);
  await db.query("SELECT public.redirect_webhook_resource('archive',$1,NULL,$2,$3::jsonb)", [
    actor,
    sub.id,
    JSON.stringify({ version: sub.version }),
  ]);
  await db.query('DELETE FROM public.redirect_api_tokens WHERE id=$1', [principal]);
  await db.query('DELETE FROM public.redirects WHERE id=$1', [link]);
  console.log(
    'Native Segment/GTM adapters: actual HTTP -> authenticated conversion handler -> migrated SQL -> signed real outbox payload -> native Segment.track; limited server key, duplicate lead, exact sale decimals, Google consent gate and no feedback-loop requests passed. External provider runtime/account installation remains unverified.',
  );
}
