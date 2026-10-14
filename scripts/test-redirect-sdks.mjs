import sharp from 'sharp';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import ts from 'typescript';
import { createRedirectTestDb } from './lib/redirect-test-db.mjs';

const db = await createRedirectTestDb();
await db.exec('SET ROLE service_role; SET request.jwt.claims = \'{"role":"service_role"}\'');
let handler;
let policyRuntime;
const pieces = [
  '_shared/redirect-api.ts',
  '_shared/redirect-presentation.ts',
  '_shared/link-policy.ts',
  '_shared/redirect-policy-api.ts',
  '_shared/redirect-links.ts',
  '_shared/redirect-analytics.ts',
  '_shared/redirect-relay.ts',
  '_shared/redirect-reports.ts',
  'redirect-api/index.ts',
].map((file) =>
  readFileSync('supabase/functions/' + file, 'utf8')
    .replace(/^import .*;\s*$/gm, '')
    .replace(/^export\s+/gm, ''),
);
const code = ts.transpileModule(pieces.join('\n'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
}).outputText;
const jsonArgs = new Set(['p_event', 'p_filters', 'p_values', 'p_operations','p_patch','p_password_hash']);
const artwork = await sharp({
  create: { width: 1200, height: 630, channels: 3, background: 'white' },
})
  .png()
  .toBuffer();
const uploadedArtwork = new Map();
const service = {
  storage: {
    from: () => ({
      upload: async (key, bytes, options) => {
        uploadedArtwork.set(key, { bytes, options });
        return { error: null };
      },
      getPublicUrl: (key) => ({
        data: {
          publicUrl:
            'https://fixture.supabase.co/storage/v1/object/public/redirect-previews/' + key,
        },
      }),
      remove: async (keys) => {
        for (const key of keys) uploadedArtwork.delete(key);
        return { error: null };
      },
    }),
  },
  rpc: async (name, args = {}) => {
    try {
      const entries = Object.entries(args);
      const params = entries.map(([key, value]) =>
        jsonArgs.has(key)
          ? JSON.stringify(value)
          : Array.isArray(value)
            ? '{' + value.join(',') + '}'
            : value,
      );
      const sql =
        'SELECT public.' +
        name +
        '(' +
        entries.map(([key], index) => key + '=> $' + (index + 1)).join(',') +
        ') AS result';
      const result = await db.query(sql, params);
      if(name==='redirect_policy_resource'&&args.p_change_password===true&&args.p_password_hash){
        const stored=(await db.query('SELECT password_hash FROM public.redirect_link_policies WHERE redirect_id=$1',[args.p_redirect_id])).rows[0].password_hash;
        if(!await policyRuntime.verifyLinkPassword('fixture-sdk-password',stored))throw new Error('Persisted SDK password hash did not verify');
      }
      return { data: result.rows[0].result, error: null };
    } catch (error) {
      return { data: null, error: { code: error.code, message: error.message } };
    }
  },
};
const reportActor='00000000-0000-4000-8000-000000000099';
await db.query('INSERT INTO auth.users(id) VALUES($1)',[reportActor]);
await db.query("INSERT INTO public.user_roles(user_id,role) VALUES($1,'admin')",[reportActor]);
const identity={auth:{getUser:async(value)=>({data:{user:value==='fixture-account-session'?{id:reportActor,created_at:'2026-10-01T00:00:00Z',is_anonymous:false}:null},error:null})},rpc:async()=>({data:true,error:null})};
policyRuntime=new Function('Deno', 'createClient', 'crypto', code+'\nreturn {verifyLinkPassword};')(
  {
    env: { get: (key) => key==='SUPABASE_SERVICE_ROLE_KEY'?'fixture-service':key==='SUPABASE_ANON_KEY'?'fixture-anon':'fixture' },
    serve: (fn) => {
      handler = fn;
    },
  },
  (_url,key) => key==='fixture-service'?service:identity,
  webcrypto,
);
const token = 'qg_redirect_' + 'a'.repeat(64);
const digest = Buffer.from(
  await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(token)),
).toString('hex');
await db.query(
  "INSERT INTO public.redirect_api_tokens(name,token_hash,prefix,scopes,created_by,expires_at) VALUES('SDK fixture',$1,'fixture',ARRAY['links:read','links:write','workspace:read','workspace:write','conversions:write','events:read'],gen_random_uuid(),now()+interval '1 day')",
  [digest],
);
const seed = await db.query(
  "INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','sdk-attribution','/events') RETURNING id",
);
const click = await db.query(
  "SELECT public.record_redirect_visit($1,'/go/sdk-attribution',NULL,NULL,'Fixture','CH',NULL,302,NULL,'/events','{\"device\":\"desktop\"}'::jsonb) AS id",
  [seed.rows[0].id],
);
await db.exec(
  "INSERT INTO public.redirects(type,slug,target) SELECT 'SHORT','sdk-page-'||seq,'/events' FROM generate_series(1,101) AS fixtures(seq)",
);
let traps = 0,
  limited = 0;
const server = createServer(async (req, res) => {
  try {
    if (req.url === '/api/redirects/redirect-probe') {
      res.writeHead(302, { Location: '/trap' });
      res.end();
      return;
    }
    if (req.url === '/trap') {
      traps++;
      res.writeHead(200);
      res.end('{}');
      return;
    }
    if (req.url === '/api/redirects/limited-probe') {
      limited++;
      res.writeHead(429, { 'Content-Type': 'application/json', 'Retry-After': '17' });
      res.end('{"error":"Fixture rate limit"}');
      return;
    }
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const response = await handler(
      new Request(
        'http://fixture/functions/v1/redirect-api' + req.url.slice('/api/redirects'.length),
        {
          method: req.method,
          headers: req.headers,
          ...(['POST', 'PATCH', 'PUT'].includes(req.method) ? { body: Buffer.concat(chunks) } : {}),
        },
      ),
    );
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(await response.text());
  } catch (error) {
    res.writeHead(500);
    res.end(JSON.stringify({ error: error.message }));
  }
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const base = 'http://127.0.0.1:' + server.address().port + '/api/redirects';
const env = {
  ...process.env,
  REDIRECT_TEST_BASE: base,
  REDIRECT_TEST_TOKEN: token,
  REDIRECT_TEST_CLICK: click.rows[0].id,
  REDIRECT_TEST_IMAGE: artwork.toString('base64'),
};
async function run(command, args, extra = {}) {
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, { env, ...extra, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', (chunk) => (output += chunk));
    child.stderr.on('data', (chunk) => (output += chunk));
    child.on('error', reject);
    child.on('exit', (code) =>
      code === 0 ? resolve() : reject(new Error(command + ' failed: ' + output)),
    );
  });
  console.log(command + ' SDK: live HTTP → actual edge handler → isolated PostgreSQL passed');
}
try {
  mkdirSync('tmp/sdk-tests', { recursive: true });
  const compiled = ts.transpileModule(readFileSync('sdk/redirects/typescript/index.ts', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
  }).outputText;
  writeFileSync('tmp/sdk-tests/typescript.mjs', compiled);
  await run(process.execPath, ['sdk/redirects/tests/typescript.mjs']);
  await run('python3', ['sdk/redirects/tests/python.py']);
  await run('ruby', ['sdk/redirects/tests/ruby.rb']);
  await run('php', ['sdk/redirects/tests/php.php']);
  await run(process.env.REDIRECT_GO_BIN ?? 'go', ['test', './...'], { cwd: 'sdk/redirects/go' });
  if (traps !== 0 || limited !== 5)
    throw new Error('SDK followed a redirect or retried a throttled request');
  const result = await db.query(
    "SELECT count(*)::int AS leads FROM public.redirect_link_conversions WHERE kind='lead'",
  );
  if (result.rows[0].leads !== 5)
    throw new Error('Conversion retry deduplication failed across SDKs');
  const money = await db.query(
    "SELECT count(*)::int AS sales,sum(amount)::text AS total FROM public.redirect_link_conversions WHERE kind='sale'",
  );
  if (money.rows[0].sales !== 5 || money.rows[0].total !== '249.500005')
    throw new Error('SDK decimal revenue was altered');
  const examples = [
    [process.execPath, ['sdk/redirects/typescript/example.mjs'], 'typescript', {}],
    ['python3', ['sdk/redirects/python/example.py'], 'python', {}],
    ['ruby', ['sdk/redirects/ruby/example.rb'], 'ruby', {}],
    ['php', ['sdk/redirects/php/example.php'], 'php', {}],
    [
      process.env.REDIRECT_GO_BIN ?? 'go',
      ['run', './cmd/example'],
      'go',
      { cwd: 'sdk/redirects/go' },
    ],
  ];
  for (const [command, args, language, options] of examples)
    await run(command, args, {
      ...options,
      env: {
        ...env,
        REDIRECT_API_TOKEN: token,
        REDIRECT_API_BASE: base,
        REDIRECT_TARGET: '/events',
        REDIRECT_CLICK_ID: click.rows[0].id,
        REDIRECT_CUSTOMER_ID: 'example:' + language,
        REDIRECT_EVENT_ID: 'example:' + language,
        REDIRECT_AMOUNT: '1.000001',
        REDIRECT_CURRENCY: 'CHF',
      },
    });
  const exampleTotals = await db.query(
    "SELECT count(*)::int AS sales,sum(amount)::text AS total FROM public.redirect_link_conversions WHERE kind='sale'",
  );
  if (exampleTotals.rows[0].sales !== 10 || exampleTotals.rows[0].total !== '254.500010')
    throw new Error('Runnable SDK examples lost sale attribution');
  async function reportRequest(path,method='GET',body,credential='fixture-account-session',expected=200){
    const response=await fetch(base+path,{method,headers:{Authorization:'Bearer '+credential,...(body?{'Content-Type':'application/json'}:{})},...(body?{body:JSON.stringify(body)}:{})});
    const data=await response.json();if(response.status!==expected)throw new Error('Report HTTP '+path+' expected '+expected+' received '+response.status+': '+JSON.stringify(data));return data;
  }
  const saved=await reportRequest('/reports','POST',{name:'Native HTTP report',filters:{linkIds:[seed.rows[0].id]}},undefined,201);
  const plain=await reportRequest('/reports/'+saved.id+'/shares','POST',{title:'Clicks only',reportVersion:saved.version,expiresAt:null},undefined,201);
  const published=await reportRequest('/public-report','GET',undefined,'qg_report_'+plain.id);
  if(published.report.totals.clicks!==1||'leads' in published.report.totals||published.report.revenue.length||JSON.stringify(published).includes('sdk-attribution'))throw new Error('Public report exposed private/conversion fields');
  const zeroDates={start:'2000-01-01T00:00:00.000Z',end:'2000-01-02T00:00:00.000Z'};
  const narrowed=await reportRequest('/public-report','POST',{dates:zeroDates},'qg_report_'+plain.id);
  if(narrowed.report.totals.clicks!==0||narrowed.dateRange.start!==zeroDates.start)throw new Error('Public date selection ignored or failed normalization');
  await reportRequest('/public-report','POST',{dates:{linkIds:[seed.rows[0].id]}},'qg_report_'+plain.id,400);
  const guarded=await reportRequest('/reports/'+saved.id+'/shares','POST',{title:'Protected conversions',reportVersion:saved.version,includeConversions:true,password:'fixture-report-password',expiresAt:null},undefined,201);
  await reportRequest('/public-report','GET',undefined,'qg_report_'+guarded.id,401);
  await reportRequest('/public-report','POST',{password:'incorrect'},'qg_report_'+guarded.id,401);
  const unlocked=await reportRequest('/public-report','POST',{password:'fixture-report-password'},'qg_report_'+guarded.id);
  if(unlocked.report.totals.leads!==10||unlocked.report.totals.sales!==10||unlocked.report.revenue[0].amount!=='254.500010')throw new Error('Protected report conversion totals/precision changed');
  const protectedDates=await reportRequest('/public-report','POST',{password:'fixture-report-password',dates:zeroDates},'qg_report_'+guarded.id);
  if(protectedDates.report.totals.sales!==0)throw new Error('Password-protected date filtering failed');
  await reportRequest('/reports/'+saved.id+'/shares/'+guarded.id,'DELETE');
  await reportRequest('/public-report','POST',{password:'fixture-report-password'},'qg_report_'+guarded.id,404);
  console.log('Saved/share/public reports: real HTTP → edge handler → migrated PostgreSQL, real password verification, sanitized totals and revocation passed');
  console.log(
    'Five SDKs passed; no external API calls, credentials, payments or production schema were used.',
  );
} finally {
  await new Promise((resolve) => server.close(resolve));
  await db.close();
}
