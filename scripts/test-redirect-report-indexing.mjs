import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

const id = '00000000-0000-4000-8000-000000000001';
const path = '/share/redirect-report/' + id;
const shell = '<!doctype html><html><head><title>Generic</title><meta name="description" content="Generic"><meta name="robots" content="noindex,nofollow"></head><body><div id="root"></div><noscript>Generic fallback</noscript></body></html>';
const bundle = await build({
  stdin: { contents: `import {onRequest} from './functions/_middleware.ts';export default {fetch(request,env,ctx){return onRequest({request,env,next:()=>env.ASSETS.fetch(request),waitUntil:ctx.waitUntil.bind(ctx)});}}`, resolveDir: process.cwd(), sourcefile: 'redirect-report-indexing-fixture.ts', loader: 'ts' },
  bundle: true, write: false, format: 'esm', platform: 'neutral', target: 'es2022',
});
let status = 200;
let shellStatus = 200;
let report = { allowIndexing: true, title: 'Published <campaign> & "report"', linkCount: 1, includeConversions: false, report: { totals: { clicks: 7 } } };
let calls = 0;
const mf = new Miniflare(convertV4MiniflareOptions({ workers: [{ name: 'report-indexing',
  modules: true, script: bundle.outputFiles[0].text, compatibilityDate: '2026-01-01',
  bindings: { SUPABASE_URL: 'https://fixture.supabase.co', SUPABASE_ANON_KEY: 'fixture-public' },
  serviceBindings: { ASSETS: () => new Response(shell, { status: shellStatus, headers: { 'Content-Type': 'text/html', 'Cache-Control': 'public, max-age=300' } }) },
  outboundService: request => {
    if (new URL(request.url).pathname === '/functions/v1/redirect-api/public-report') {
      calls++;
      assert.equal(request.headers.get('authorization'), 'Bearer qg_report_' + id);
      return Response.json(report, { status });
    }
    // Every other backend request (branding etc.) is isolated, never networked.
    return Response.json([]);
  },
}] }));
async function read(route = path, ua = 'Mozilla/5.0') {
  const response = await mf.dispatchFetch('https://queer.guide' + route, { headers: { 'user-agent': ua } });
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(response.headers.get('Referrer-Policy'), 'no-referrer');
  return { response, html: await response.text() };
}
try {
  for (const ua of ['Mozilla/5.0', 'Googlebot']) {
    const { response, html } = await read(path, ua);
    assert.equal(response.headers.get('X-Robots-Tag'), 'index, follow');
    assert.equal((html.match(/name="robots"/g) ?? []).length, 1);
    assert.match(html, /name="robots" content="index,follow"/);
    assert.match(html, /<h1>Published &lt;campaign&gt; &amp; &quot;report&quot;<\/h1>/);
    assert.match(html, /<dt>clicks<\/dt><dd>7<\/dd>/);
    assert.doesNotMatch(html, /hreflang=/);
  }
  report = { ...report, allowIndexing: false };
  const ordinary = await read();
  assert.equal(ordinary.response.headers.get('X-Robots-Tag'), 'noindex, nofollow');
  assert.doesNotMatch(ordinary.html, /Published &lt;campaign&gt;|<dd>7<\/dd>/);
  report = { ...report, allowIndexing: true };
  for (status of [401, 404, 429, 503]) {
    const closed = await read();
    assert.equal(closed.response.headers.get('X-Robots-Tag'), 'noindex, nofollow');
    assert.match(closed.html, /name="robots" content="noindex,nofollow"/);
    assert.doesNotMatch(closed.html, /Published &lt;campaign&gt;|<dd>7<\/dd>/);
  }
  status = 200;
  const before = calls;
  for (const route of [path + '?index=true', '/de' + path]) {
    assert.equal((await read(route)).response.headers.get('X-Robots-Tag'), 'noindex, nofollow');
  }
  assert.equal(calls, before);
  for (shellStatus of [404, 500]) {
    const unavailableShell = await read();
    assert.equal(unavailableShell.response.status, shellStatus);
    assert.equal(unavailableShell.response.headers.get('X-Robots-Tag'), 'noindex, nofollow');
  }
  console.log('Actual middleware + workerd HTMLRewriter: explicit indexing, one robots tag, escaped public summary for humans/bots; noindex for default/password/revoked/rate-limited/unavailable/localized/query pages; all HTML remains no-store.');
} finally { await mf.dispose(); }
