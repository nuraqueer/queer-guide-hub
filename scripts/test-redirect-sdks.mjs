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
  '_shared/redirect-qr-style.ts',
  '_shared/redirect-domains.ts',
  '_shared/redirect-domain-provider.ts',
  '_shared/redirect-presentation.ts',
  '_shared/link-policy.ts',
  '_shared/redirect-policy-api.ts',
  '_shared/redirect-links.ts',
  '_shared/redirect-manual-records.ts',
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
const jsonArgs = new Set(['p_result', 'p_dates', 'p_event', 'p_filters', 'p_values', 'p_operations','p_patch','p_password_hash']);
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
const sdkRootDomain=webcrypto.randomUUID();
await db.query("INSERT INTO public.redirect_domains(id,hostname,verification_token,ownership_state,verified_at,verified_until,provider_id,routing_provider_id,routing_protocol,routing_seen_at) VALUES($1,'root-sdk.example.com',repeat('a',64),'verified',now(),now()+interval '1 day','fixture-root-provider','fixture-root-provider',1,now())",[sdkRootDomain]);
await db.query("INSERT INTO public.redirect_domain_jobs(domain_id,zone_id,cname_target,requested_by,state,provider_status,ssl_status,checked_at) VALUES($1,repeat('a',32),'links.queer.guide',$2,'ready','active','active',now())",[sdkRootDomain,reportActor]);
const identity={auth:{getUser:async(value)=>({data:{user:value==='fixture-account-session'?{id:reportActor,created_at:'2026-10-01T00:00:00Z',is_anonymous:false}:null},error:null})},rpc:async()=>({data:true,error:null})};
let dnsCalls=0,dnsMissing=false;
const providerConfig={zoneId:'a'.repeat(32),token:'fixture-provider-token',cnameTarget:'links.queer.guide'};
const providerObjects=new Map();let providerCreates=0,providerDeletes=0,providerRestarts=0;
const fixtureDnsFetch=async (input,options)=>{const url=new URL(String(input));
if(url.origin==='https://api.cloudflare.com'){
 if(new Headers(options?.headers).get('Authorization')!=='Bearer '+providerConfig.token||!url.pathname.startsWith('/client/v4/zones/'+providerConfig.zoneId+'/custom_hostnames'))throw new Error('Invalid fixture provider credentials/zone');
 const method=options?.method??'GET',tail=url.pathname.split('/custom_hostnames')[1];
 if(method==='POST'&&!tail){providerCreates++;const body=JSON.parse(options.body),item={id:webcrypto.randomUUID(),hostname:body.hostname,status:'active',ssl:{type:'dv',method:'txt',status:'pending_validation',validation_records:[{txt_name:'_acme-challenge.'+body.hostname,txt_value:'fixture-validation'}]}};providerObjects.set(item.id,item);return Response.json({success:true,result:item});}
 if(method==='GET'&&!tail)return Response.json({success:true,result:[...providerObjects.values()].filter(item=>item.hostname===url.searchParams.get('hostname'))});
 const item=providerObjects.get(tail.slice(1));if(!item)return Response.json({success:false},{status:404});
 if(method==='PATCH'){const body=JSON.parse(options.body);if(JSON.stringify(body)!==JSON.stringify({ssl:{type:item.ssl.type,method:item.ssl.method}}))throw new Error('Restart changed provider SSL settings');providerRestarts++;item.ssl.status='pending_validation';return Response.json({success:true,result:item});}
 if(method==='DELETE'){providerDeletes++;providerObjects.delete(item.id);return Response.json({success:true,result:{id:item.id}});}
 return Response.json({success:true,result:item});
}
if(url.origin!=='https://cloudflare-dns.com'||url.pathname!=='/dns-query')throw new Error('Unexpected external fixture request');dnsCalls++;const hostname=url.searchParams.get('name').replace(/^_qg-redirect\./,'');const row=(await db.query('SELECT verification_token FROM public.redirect_domains WHERE hostname=$1',[hostname])).rows[0];return new Response(JSON.stringify({Status:0,Question:[{name:url.searchParams.get('name'),type:16}],Answer:row&&!dnsMissing?[{name:url.searchParams.get('name'),type:16,data:'\"qg-redirect='+row.verification_token+'\"'}]:[]}),{headers:{'Content-Type':'application/dns-json'}});};
policyRuntime=new Function('Deno', 'createClient', 'crypto', 'fetch', code+'\nreturn {verifyLinkPassword,dispatchRedirectDomainJobs};')(
  {
    env: { get: (key) => key==='SUPABASE_SERVICE_ROLE_KEY'?'fixture-service':key==='SUPABASE_ANON_KEY'?'fixture-anon':key==='REDIRECT_CF_ZONE_ID'?providerConfig.zoneId:key==='REDIRECT_CF_API_TOKEN'?providerConfig.token:key==='REDIRECT_CNAME_TARGET'?providerConfig.cnameTarget:'fixture' },
    serve: (fn) => {
      handler = fn;
    },
  },
  (_url,key) => key==='fixture-service'?service:identity,
  webcrypto,
  fixtureDnsFetch,
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
          ...(['POST', 'PATCH', 'PUT', 'DELETE'].includes(req.method) ? { body: Buffer.concat(chunks) } : {}),
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
  REDIRECT_TEST_ROOT_DOMAIN: sdkRootDomain,
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
  await db.query('DELETE FROM public.redirect_domain_jobs WHERE domain_id=$1',[sdkRootDomain]);
  await db.query('DELETE FROM public.redirect_domains WHERE id=$1',[sdkRootDomain]);
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
  const domain=await reportRequest('/domains','POST',{hostname:'LINKS.Example.com.'},undefined,201);
  if(domain.hostname!=='links.example.com'||domain.ownershipVerified||domain.providerConnected)throw new Error('Domain creation claimed readiness');
  await reportRequest('/domains','GET',undefined,token,403);
  await reportRequest('/domains','POST',{hostname:'https://example.com'},undefined,400);
  const verifiedDomain=await reportRequest('/domains/'+domain.id+'/verify','POST',{version:domain.version});
  if(!verifiedDomain.ownershipVerified||verifiedDomain.providerConnected||dnsCalls!==1)throw new Error('Real domain API verification failed or claimed TLS');
  await reportRequest('/domains/'+domain.id+'/verify','POST',{version:verifiedDomain.version},undefined,429);
  if(dnsCalls!==1)throw new Error('DNS provider called before cooldown enforcement');
  await reportRequest('/domains/'+domain.id,'PATCH',{version:domain.version,rootUrl:'https://example.org/'},undefined,409);
  let defaults=await reportRequest('/domains/'+domain.id,'PATCH',{version:verifiedDomain.version,rootUrl:'https://example.org/home'});
  const connected=await reportRequest('/domains/'+domain.id+'/provider/connect','POST',{version:defaults.version});
  if(providerCreates!==0||connected.provider.state!=='queued')throw new Error('Provider request performed inline external writes');
  await policyRuntime.dispatchRedirectDomainJobs(service,providerConfig,fixtureDnsFetch);
  let providerView=await reportRequest('/domains/'+domain.id);
  if(providerCreates!==1||providerView.provider.hostnameStatus!=='active'||providerView.provider.certificateReady||providerView.provider.certificateStatus!=='pending_validation')throw new Error('Hostname and TLS states were conflated');
  await reportRequest('/domains/'+domain.id+'/provider/restart-validation','POST',{version:providerView.version},token,403);
  providerView=await reportRequest('/domains/'+domain.id+'/provider/restart-validation','POST',{version:providerView.version});
  if(!providerView.provider.validationRestartPending||providerRestarts)throw new Error('Validation restart was not durably queued');
  await policyRuntime.dispatchRedirectDomainJobs(service,providerConfig,fixtureDnsFetch);
  providerView=await reportRequest('/domains/'+domain.id);
  if(providerRestarts!==1||providerView.provider.validationRestartPending||!providerView.provider.validationRestartStartedAt||providerCreates!==1)throw new Error('Restart did not PATCH exact existing provider once');
  await reportRequest('/domains/'+domain.id+'/provider/restart-validation','POST',{version:providerView.version},undefined,400);
  await reportRequest('/domains/'+domain.id+'/provider/refresh','POST',{version:providerView.version});
  await policyRuntime.dispatchRedirectDomainJobs(service,providerConfig,fixtureDnsFetch);
  providerView=await reportRequest('/domains/'+domain.id);
  if(providerRestarts!==1)throw new Error('Status refresh repeated validation PATCH');
  for(const item of providerObjects.values())item.ssl.status='active';
  await reportRequest('/domains/'+domain.id+'/provider/refresh','POST',{version:providerView.version});
  await policyRuntime.dispatchRedirectDomainJobs(service,providerConfig,fixtureDnsFetch);
  providerView=await reportRequest('/domains/'+domain.id);
  if(!providerView.provider.certificateReady||providerCreates!==1)throw new Error('TLS polling recreated the hostname or lost readiness');
  await reportRequest('/links','POST',{slug:'same-domain-slug',target:'https://example.org/branded',domainId:domain.id},undefined,400);
  await db.query('SELECT public.record_redirect_domain_route($1)',[domain.hostname]);
  let primary=await reportRequest('/domain-preference');
  await reportRequest('/domain-preference','GET',undefined,token,403);
  await reportRequest('/domain-preference','PATCH',{domainId:domain.id,version:'invalid'},undefined,400);
  const originalPrimaryVersion=primary.version;
  primary=await reportRequest('/domain-preference','PATCH',{domainId:domain.id,version:primary.version});
  await reportRequest('/domain-preference','PATCH',{domainId:null,version:originalPrimaryVersion},undefined,409);
  const readyChoices=await reportRequest('/domain-choices?limit=1','GET',undefined,token);
  if(readyChoices.count!==1||readyChoices.primaryDomainId!==domain.id||readyChoices.primaryUnavailable||Object.keys(readyChoices.data[0]).sort().join(',')!=='hostname,id')throw new Error('Public domain choices leaked setup data or lost primary');

  const branded=(await reportRequest('/links','POST',{slug:'same-domain-slug',target:'https://example.org/branded',domainId:domain.id},undefined,201)).link;
  const builtinDomainLink=(await reportRequest('/links','POST',{slug:'same-domain-slug',target:'https://example.org/builtin'},undefined,201)).link;
  if(branded.shortUrl!=='https://links.example.com/same-domain-slug'||branded.id===builtinDomainLink.id)throw new Error('HTTP hostname namespace isolation failed');
  await reportRequest('/qr-styles/workspace','POST',{},undefined,405);
  let qrWorkspace=await reportRequest('/qr-styles/workspace');
  qrWorkspace=await reportRequest('/qr-styles/workspace','PATCH',{version:qrWorkspace.version,style:{dots:'joined'}});
  await reportRequest('/qr-styles/workspace','PATCH',{version:null,style:{dots:'circle'}},undefined,409);
  await reportRequest('/qr-styles/workspace','GET',undefined,token,403);
  let qrDomain=await reportRequest('/qr-styles/domains/'+domain.id);
  if(qrDomain.effectiveStyle.dots!=='joined')throw new Error('Domain QR did not inherit workspace');
  qrDomain=await reportRequest('/qr-styles/domains/'+domain.id,'PATCH',{version:qrDomain.version,style:{border:'rounded'}});
  const qrEffective=await reportRequest('/qr-styles/links/'+branded.id,'GET',undefined,token);
  if(qrEffective.source!=='domain'||qrEffective.style.dots!=='joined'||qrEffective.style.border!=='rounded'||Object.keys(qrEffective).sort().join(',')!=='id,source,style')throw new Error('Scoped QR style precedence or public fields incorrect');
  const qrBatch=await reportRequest('/qr-styles/links?ids='+branded.id,'GET',undefined,token);
  if(qrBatch.data[0].id!==branded.id)throw new Error('Batched QR style lookup failed');
  await reportRequest('/qr-styles/links?ids='+branded.id+','+branded.id,'GET',undefined,token,400);
  await reportRequest('/qr-styles/domains/'+domain.id,'PATCH',{version:qrDomain.version,style:null},token,403);
  await reportRequest('/qr-styles/domains/'+domain.id,'PATCH',{version:qrDomain.version,style:null});
  await reportRequest('/qr-styles/workspace','PATCH',{version:qrWorkspace.version,style:null});
  console.log('Saved QR appearance: actual owner HTTP/migrated SQL verifies version conflicts, workspace/domain inheritance, minimal scoped single/batch reads, key write denial and reset.');
  const domainPage=await reportRequest('/links?filters='+encodeURIComponent(JSON.stringify({domainId:domain.id})));
  if(domainPage.count!==1||domainPage.data[0].id!==branded.id)throw new Error('HTTP domain filter mixed namespaces');
  const updatedBranded=(await reportRequest('/links/upsert','PUT',{slug:'same-domain-slug',target:'https://example.org/updated',domainId:domain.id})).link;
  if(updatedBranded.id!==branded.id||(await reportRequest('/links/'+builtinDomainLink.id)).target!=='https://example.org/builtin')throw new Error('HTTP upsert crossed domain namespace');
  await db.query("UPDATE public.redirect_domains SET verified_until=now()+interval '5 hours',next_check_at=now()-interval '1 second' WHERE id=$1",[domain.id]);
  await reportRequest('/domains/'+domain.id+'/provider/refresh','POST',{version:providerView.version});
  await policyRuntime.dispatchRedirectDomainJobs(service,providerConfig,fixtureDnsFetch);
  providerView=await reportRequest('/domains/'+domain.id);
  if(!providerView.routingReady||dnsCalls!==2||Date.parse(providerView.verifiedUntil)-Date.now()<23*3600000)throw new Error('Background ownership renewal or current routing proof failed');
  await reportRequest('/links/'+branded.id,'DELETE');await reportRequest('/links/'+builtinDomainLink.id,'DELETE');
  console.log('Hostname-scoped HTTP links: route-proof gating, canonical URLs, same-slug isolation, domain filters, scoped upsert and background DNS renewal passed.');
  let manual=await reportRequest('/manual-records','POST',{values:{type:'PATH',source_path:'/manual-http',match_kind:'WILDCARD',target:'/events',notes:'HTTP notes',start_at:'2020-01-01T00:00:00Z',end_at:'2030-01-01T00:00:00Z',click_limit:11,query_mode:'OVERRIDE',query_override:{audience:'friends'},utm_defaults:{utm_source:'print'}}},undefined,201);
  await reportRequest('/manual-records/'+manual.id,'GET',undefined,token,403);
  await reportRequest('/manual-records/'+manual.id,'PATCH',{values:{click_count:0},expectedUpdatedAt:manual.updated_at},undefined,400);
  const oldManualTime=manual.updated_at;
  manual=await reportRequest('/manual-records/'+manual.id,'PATCH',{values:{type:'SHORT',slug:'manual-http',domain_id:domain.id},expectedUpdatedAt:manual.updated_at});
  if(manual.type!=='SHORT'||manual.domain_hostname!==domain.hostname||manual.notes!=='HTTP notes'||manual.click_limit!==11||manual.source_path!==null)throw new Error('Atomic manual HTTP conversion lost fields');
  await reportRequest('/manual-records/'+manual.id,'PATCH',{values:{target:'/stale'},expectedUpdatedAt:oldManualTime},undefined,409);
  await reportRequest('/links/'+manual.id+'/policy','PATCH',{policy:{track_conversions:true}});
  manual=await reportRequest('/manual-records/'+manual.id);
  manual=await reportRequest('/manual-records/'+manual.id,'PATCH',{values:{end_at:null},expectedUpdatedAt:manual.updated_at});
  const manualPolicy=await reportRequest('/links/'+manual.id+'/policy');if(manualPolicy.policy.expires_at||!manualPolicy.policy.track_conversions)throw new Error('Manual expiry failed to preserve other policy fields');
  const disconnect=await reportRequest('/domains/'+domain.id+'/provider/disconnect','POST',{version:providerView.version});
  if(disconnect.provider.certificateReady||providerObjects.size!==1)throw new Error('Disconnect did not close readiness before cleanup');
  const usedDomains=await reportRequest('/linked-domains?limit=1','GET',undefined,token);
  if(usedDomains.count!==1||usedDomains.data[0].id!==domain.id||usedDomains.data[0].hostname!==domain.hostname||usedDomains.data[0].linkCount!==1||!/^[a-f0-9]{32}$/.test(usedDomains.revision)||Object.keys(usedDomains.data[0]).sort().join(',')!=='hostname,id,linkCount')throw new Error('Management facet lost inactive domain or exposed private fields');
  const domainLinks=await reportRequest('/links?filters='+encodeURIComponent(JSON.stringify({domainId:domain.id})),'GET',undefined,token);
  if(domainLinks.count!==1||domainLinks.data[0].id!==manual.id)throw new Error('Inactive domain filter failed');
  const builtinLinks=await reportRequest('/links?filters='+encodeURIComponent(JSON.stringify({domainId:null})),'GET',undefined,token);
  if(!builtinLinks.count||builtinLinks.data.some(link=>link.domainId!==null))throw new Error('Builtin filter mixed namespaces');

  manual=await reportRequest('/manual-records/'+manual.id,'PATCH',{values:{notes:'Repaired while unavailable'},expectedUpdatedAt:manual.updated_at});
  manual=await reportRequest('/manual-records/'+manual.id,'PATCH',{values:{type:'PATH',source_path:'/manual-return',domain_id:null},expectedUpdatedAt:manual.updated_at});
  if(manual.domain_id!==null||manual.domain_hostname!==null||manual.slug!==null||manual.notes!=='Repaired while unavailable')throw new Error('Manual repair/path conversion failed');
  const afterMoveFacets=await reportRequest('/linked-domains','GET',undefined,token);
  if(afterMoveFacets.count!==0||afterMoveFacets.revision===usedDomains.revision)throw new Error('Moved link left a stale management domain facet');
  console.log('Linked-domain facets: actual scoped HTTP proves inactive-domain visibility, minimal public fields, custom/builtin filtering and revision changes after a move.');

  console.log('Manual owner API: actual HTTP → migrated SQL proves full fields, atomic branded conversions, stale/readonly/key denial, policy-expiry sync and unavailable-domain repair.');
  const unavailablePrimary=await reportRequest('/domain-choices');
  if(!unavailablePrimary.primaryUnavailable||unavailablePrimary.primaryDomainId!==domain.id||unavailablePrimary.count!==0)throw new Error('Disconnected primary silently became builtin');

  await policyRuntime.dispatchRedirectDomainJobs(service,providerConfig,fixtureDnsFetch);
  defaults=await reportRequest('/domains/'+domain.id);
  if(defaults.providerConnected||providerObjects.size||providerDeletes!==1||defaults.provider.state!=='disconnected')throw new Error('Provider cleanup failed or orphaned an object');
  console.log('Hostname lifecycle: actual owner HTTP → migrated queue → actual provider adapter → isolated Cloudflare API; pending TLS vs active, one POST, owner-only queued validation restart, exact one PATCH, cooldown, GET-only refresh and asynchronous disconnect/delete passed.');
  await db.query("UPDATE public.redirect_domains SET next_check_at=now()-interval '1 second' WHERE id=$1",[domain.id]);
  dnsMissing=true;
  const lost=await reportRequest('/domains/'+domain.id+'/verify','POST',{version:defaults.version});
  if(lost.ownershipState!=='lost'||lost.ownershipVerified)throw new Error('Missing DNS proof preserved ownership');
  await reportRequest('/domains/'+domain.id,'DELETE',{version:lost.version});
  await reportRequest('/domains/'+domain.id,'GET',undefined,undefined,404);
  const clearedPrimary=await reportRequest('/domain-preference');
  if(clearedPrimary.domainId!==null||clearedPrimary.version===primary.version||!clearedPrimary.ready)throw new Error('Domain deletion did not version and clear primary reference');
  console.log('Domain choices/primary: real HTTP proves ready-only public fields, key read scope, owner-only preference, stale-write conflicts, disconnected default warning and FK/version cleanup.');

  console.log('Domain registry: real HTTP handler → migrated SQL → isolated DNS response, fresh ownership, cooldown before DNS, lost proof, versioned defaults/deletion and key rejection passed; no DNS/provider writes.');
  const saved=await reportRequest('/reports','POST',{name:'Native HTTP report',filters:{linkIds:[seed.rows[0].id]}},undefined,201);
  const plain=await reportRequest('/reports/'+saved.id+'/shares','POST',{title:'Clicks only',reportVersion:saved.version,expiresAt:null},undefined,201);
  const published=await reportRequest('/public-report','GET',undefined,'qg_report_'+plain.id);
  if(published.allowIndexing!==false||published.report.totals.clicks!==1||'leads' in published.report.totals||published.report.revenue.length||JSON.stringify(published).includes('sdk-attribution'))throw new Error('Public report exposed private/conversion fields');
  const indexedShare=await reportRequest('/reports/'+saved.id+'/shares','POST',{title:'Indexed HTTP publication',reportVersion:saved.version,allowIndexing:true,expiresAt:null},undefined,201);
  const indexedPublic=await reportRequest('/public-report','GET',undefined,'qg_report_'+indexedShare.id);
  if(indexedPublic.allowIndexing!==true)throw new Error('Explicit indexing choice not exposed by actual HTTP');
  await reportRequest('/reports/'+saved.id+'/shares','POST',{title:'Rejected combination',reportVersion:saved.version,allowIndexing:true,password:'fixture-report-password'},undefined,400);
  await reportRequest('/reports/'+saved.id+'/shares/'+indexedShare.id,'DELETE');
  await reportRequest('/public-report','GET',undefined,'qg_report_'+indexedShare.id,404);
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
