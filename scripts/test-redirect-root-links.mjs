import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import ts from 'typescript';
import { createRedirectTestDb } from './lib/redirect-test-db.mjs';
const db = await createRedirectTestDb();
await db.exec('SET ROLE service_role');
const secret = 'fixture-root-secret-'.repeat(3);
let handle;
const source = [
  '_shared/link-policy.ts',
  '_shared/redirect-visitor.ts',
  '_shared/redirect-relay.ts',
  '_shared/redirect-presentation.ts',
  '_shared/redirect-password-page.ts',
  '_shared/redirect-domain-relay.ts',
  'redirect-handler/index.ts',
]
  .map((file) =>
    readFileSync('supabase/functions/' + file, 'utf8')
      .replace(/^import .*;\s*$/gm, '')
      .replace(/^export\s+/gm, ''),
  )
  .join('\n');
const service = {
  rpc: async (name, args) => {
    try {
      const entries = Object.entries(args ?? {});
      const result = await db.query(
        'SELECT public.' +
          name +
          '(' +
          entries.map(([key], i) => key + '=> $' + (i + 1)).join(',') +
          ') AS data',
        entries.map(([key, value]) =>
          ['p_metadata', 'p_operations'].includes(key) ? JSON.stringify(value) : value,
        ),
      );
      return { data: result.rows[0].data, error: null };
    } catch (error) {
      return { data: null, error };
    }
  },
  from(table) {
    assert.ok(['redirects', 'redirect_link_policies', 'redirect_domains'].includes(table));
    const filters = [];
    const query = {
      select() {
        return query;
      },
      eq(key, value) {
        assert.match(key, /^[a-z_]+$/);
        filters.push([key, value]);
        return query;
      },
      is(key, value) {
        assert.equal(value, null);
        return query.eq(key, value);
      },
      async maybeSingle() {
        try {
          const result = await db.query(
            'SELECT * FROM public.' +
              table +
              ' WHERE ' +
              filters.map(([key], i) => key + ' IS NOT DISTINCT FROM $' + (i + 1)).join(' AND '),
            filters.map(([, value]) => value),
          );
          assert.ok(result.rows.length <= 1);
          return {
            data: result.rows[0] ? JSON.parse(JSON.stringify(result.rows[0])) : null,
            error: null,
          };
        } catch (error) {
          return { data: null, error };
        }
      },
    };
    return query;
  },
};
const values = {
  SUPABASE_URL: 'https://fixture.supabase.co',
  SUPABASE_SERVICE_ROLE_KEY: 'fixture-service',
  REDIRECT_RELAY_SECRET: secret,
};
new Function(
  'Deno',
  'createClient',
  'crypto',
  ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
  }).outputText,
)(
  {
    env: { get: (key) => values[key] },
    serve: (fn) => {
      handle = fn;
    },
  },
  () => service,
  webcrypto,
);
const relayCode = ts.transpileModule(
  readFileSync('supabase/functions/_shared/redirect-domain-relay.ts', 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } },
).outputText;
const relay = await import(
  'data:text/javascript;base64,' + Buffer.from(relayCode).toString('base64')
);
const workerExports = {};
const workerCode = ts.transpileModule(readFileSync('workers/redirect-domains/index.ts', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
}).outputText;
new Function('require', 'exports', 'fetch', workerCode)(
  (id) => {
    assert.match(id, /redirect-domain-relay$/);
    return relay;
  },
  workerExports,
  (input, init) => handle(new Request(input, init)),
);
const worker = workerExports.default;
const passwordCode = ts.transpileModule(
  readFileSync('supabase/functions/_shared/link-policy.ts', 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } },
).outputText;
const policy = await import(
  'data:text/javascript;base64,' + Buffer.from(passwordCode).toString('base64')
);
const actor = webcrypto.randomUUID();
await db.query('INSERT INTO auth.users(id) VALUES($1)', [actor]);
await db.query("INSERT INTO public.user_roles VALUES($1,'admin')", [actor]);
const domain = (
  await db.query(
    'SELECT public.redirect_domain_resource(\'create\',$1,p_values=>\'{"hostname":"root-http.example.com","rootUrl":"https://example.org/legacy"}\') AS d',
    [actor],
  )
).rows[0].d;
await db.query(
  "UPDATE public.redirect_domains SET ownership_state='verified',verified_at=now(),verified_until=now()+interval '1 day',provider_id='fixture-root',routing_provider_id='fixture-root',routing_protocol=1,routing_seen_at=now() WHERE id=$1",
  [domain.id],
);
await db.query(
  "INSERT INTO public.redirect_domain_jobs(domain_id,zone_id,cname_target,requested_by,state,provider_status,ssl_status,checked_at) VALUES($1,repeat('a',32),'links.queer.guide',$2,'ready','active','active',now())",
  [domain.id, actor],
);
async function open(path = '/', { method = 'GET', password, agent = 'Fixture browser' } = {}) {
  return worker.fetch(
    new Request('https://root-http.example.com' + path, {
      method,
      headers: {
        'cf-connecting-ip': '192.0.2.15',
        'User-Agent': agent,
        ...(password ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}),
      },
      ...(password ? { body: new URLSearchParams({ password }).toString() } : {}),
    }),
    {
      SUPABASE_URL: values.SUPABASE_URL,
      SUPABASE_ANON_KEY: 'fixture-public',
      REDIRECT_RELAY_SECRET: secret,
    },
  );
}

async function total() {
  return (await db.query('SELECT click_count FROM public.redirects WHERE id=$1', [root.id])).rows[0]
    .click_count;
}
assert.equal((await open()).headers.get('Location'), 'https://example.org/legacy');
const created = await service.rpc('redirect_management_mutate', {
  p_operations: [
    {
      operation: 'create',
      data: {
        domainId: domain.id,
        isDomainRoot: true,
        target: 'https://example.org/home',
        clickLimit: 2,
      },
    },
  ],
  p_actor_id: actor,
});
assert.equal(created.error, null);
const root = created.data[0].link;
assert.equal(root.shortUrl, 'https://root-http.example.com/');
await db.query(
  'INSERT INTO public.redirect_link_policies(redirect_id,policy,password_hash) VALUES($1,$2,$3)',
  [
    root.id,
    JSON.stringify({
      track_conversions: true,
      device_targets: { ios: 'https://example.org/ios' },
      preview: { title: 'Root preview' },
    }),
    JSON.stringify(await policy.hashLinkPassword('fixture-root-password')),
  ],
);
const passwordBrand = (
  await db.query(
    'SELECT public.redirect_password_branding_resource(\'patch\',$1,NULL,$2,\'{"version":null,"brandName":"Community & <root>"}\'::jsonb) AS value',
    [actor, root.id],
  )
).rows[0].value;
const passwordAsset = (
  await db.query(
    "SELECT public.reserve_redirect_password_logo($1,NULL,$2,$3,'image/png',100,64,64,repeat('a',64)) AS value",
    [actor, root.id, passwordBrand.version],
  )
).rows[0].value;
await db.query('SELECT public.finish_redirect_password_logo($1,NULL,$2,$3)', [
  actor,
  root.id,
  passwordAsset.id,
]);
const brandedChallenge = await open();
assert.equal(brandedChallenge.status, 401);
const brandedHtml = await brandedChallenge.text();
assert.ok(brandedHtml.includes('Community &amp; &lt;root&gt;'));
assert.ok(
  brandedHtml.includes('/storage/v1/object/public/redirect-brand-assets/' + passwordAsset.key),
);
assert.ok(brandedHtml.includes('crossorigin="anonymous" referrerpolicy="no-referrer"'));
assert.ok(!brandedHtml.includes('https://example.org/home'));
assert.ok(
  brandedChallenge.headers
    .get('Content-Security-Policy')
    .includes('img-src https://fixture.supabase.co'),
);
const brandedHead = await open('/', { method: 'HEAD' });
assert.equal(brandedHead.status, 401);
assert.equal(await brandedHead.text(), '');
assert.equal((await open()).status, 401);
assert.equal((await open('/', { method: 'HEAD' })).status, 401);
assert.equal(await total(), 0);
const wrong = await open('/', { method: 'POST', password: 'wrong' });
assert.equal(wrong.status, 401);
assert.equal(wrong.headers.get('Location'), null);
assert.ok((await wrong.text()).includes('Community &amp; &lt;root&gt;'));
assert.equal(await total(), 0);
const granted = await open('/?qg_qr=1&utm_source=poster', {
  method: 'POST',
  password: 'fixture-root-password',
});
assert.equal(granted.status, 302);
assert.match(granted.headers.get('Location'), /^https:\/\/example.org\/home\?/);
assert.ok(new URL(granted.headers.get('Location')).searchParams.get('qg_click_id'));
assert.equal(await total(), 1);
const event = (
  await db.query('SELECT path,visitor,query FROM public.redirect_events WHERE redirect_id=$1', [
    root.id,
  ])
).rows[0];
assert.equal(event.path, '/');
assert.equal(event.visitor.domain, 'root-http.example.com');
assert.equal(event.visitor.is_qr, true);
assert.equal(event.query, 'utm_source=poster');
await db.query('UPDATE public.redirect_link_policies SET password_hash=NULL WHERE redirect_id=$1', [
  root.id,
]);
const preview = await open('/', { agent: 'Twitterbot/1.0' });
assert.equal(preview.status, 200);
assert.match(
  await preview.text(),
  /property="og:url" content="https:\/\/root-http\.example\.com\/"/,
);
assert.equal(await total(), 1);
assert.equal((await open('/', { method: 'HEAD' })).status, 302);
assert.equal(await total(), 1);
const ios = await open('/', { agent: 'iPhone' });
assert.equal(new URL(ios.headers.get('Location')).pathname, '/ios');
assert.equal(await total(), 2);
assert.equal((await open()).status, 410);
assert.equal(await total(), 2);
await db.query('UPDATE public.redirects SET is_enabled=false WHERE id=$1', [root.id]);
assert.equal((await open()).status, 404);
assert.notEqual((await open()).headers.get('Location'), 'https://example.org/legacy');
await db.query(
  "UPDATE public.redirects SET is_enabled=true,start_at=now()+interval '1 day' WHERE id=$1",
  [root.id],
);
assert.equal((await open()).status, 404);
await db.query(
  "UPDATE public.redirects SET start_at=NULL,end_at=now()-interval '1 day' WHERE id=$1",
  [root.id],
);
assert.equal((await open()).status, 410);
assert.equal(await total(), 2);
assert.equal((await open('/' + root.slug)).status, 404);
await db.query('DELETE FROM public.redirects WHERE id=$1', [root.id]);
assert.equal((await open()).headers.get('Location'), 'https://example.org/legacy');
await db.close();
console.log(
  'Managed roots: actual Worker → signed resolver → migrated PostgreSQL verifies legacy fallback only when absent, password POST/HEAD denial, targeting, root preview canonical URL, QR/conversion attribution, atomic quota, scheduling/expiry/disabled behavior and inaccessible internal slug. No external requests.',
);
