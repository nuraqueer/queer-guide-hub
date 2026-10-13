import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { webcrypto } from 'node:crypto';
import ts from 'typescript';
import { describe, expect, it, vi } from 'vitest';
import { hashLinkPassword } from '../../../../supabase/functions/_shared/link-policy';

function runtime() {
  const source = readFileSync(
    join(__dirname, '../../../../supabase/functions/redirect-handler/index.ts'),
    'utf8',
  ).replace(/^import .*;\s*$/gm, '');
  const shared = readFileSync(
    join(__dirname, '../../../../supabase/functions/_shared/link-policy.ts'),
    'utf8',
  ).replace(/^export\s+/gm, '');
  const code = ts.transpileModule(shared + '\n' + source, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
  }).outputText;
  let handler: ((request: Request) => Promise<Response>) | undefined;
  const state = {
    link: {
      id: 'fixture',
      target: 'https://example.com/pride?utm_campaign=poster#details',
      status_code: 302,
      query_mode: 'PRESERVE',
      query_override: null,
      utm_defaults: null,
      is_enabled: true,
      start_at: null,
      end_at: null as string | null,
    },
    settings: { policy: {}, password_hash: null as unknown },
    failed: false,
    quota: true,
  };
  const rpc = vi.fn(async (name: string, _args?: Record<string, unknown>) => ({
    error: null,
    data: name === 'record_redirect_visit' ? (state.quota ? 'click-id' : null) : [],
  }));
  const db = {
    rpc,
    from: (table: string) => {
      const query = {
        select() {
          return query;
        },
        eq() {
          return query;
        },
        async maybeSingle() {
          return {
            error: state.failed ? { message: 'offline' } : null,
            data: table === 'redirects' ? state.link : state.settings,
          };
        },
      };
      return query;
    },
  };
  const deno = {
    env: {
      get: (key: string) =>
        key === 'SUPABASE_URL' ? 'https://fixture.supabase.co' : 'fixture-key',
    },
    serve: (callback: typeof handler) => {
      handler = callback;
    },
  };
  new Function('Deno', 'createClient', 'crypto', code)(deno, () => db, webcrypto);
  return {
    state,
    rpc,
    invoke: (method = 'GET', query = 'utm_source=qr', body?: string) =>
      handler!(
        new Request(
          'https://fixture.supabase.co/functions/v1/redirect-handler?slug=pride-qr&q=' +
            encodeURIComponent(query),
          {
            method,
            headers: {
              'x-qg-visitor-country': 'CH',
              'cf-ipcountry': 'US',
              ...(body ? { 'content-type': 'application/x-www-form-urlencoded' } : {}),
            },
            body,
          },
        ),
      ),
  };
}
describe('live short-link resolver', () => {
  it('records GET and visitor context, but HEAD does not count or consume quota', async () => {
    const run = runtime();
    const head = await run.invoke('HEAD');
    expect(head.status).toBe(302);
    expect(head.headers.get('Location')).toBe(
      'https://example.com/pride?utm_campaign=poster&utm_source=qr#details',
    );
    expect(run.rpc).not.toHaveBeenCalled();
    expect((await run.invoke()).status).toBe(302);
    expect(
      run.rpc.mock.calls.find(([name]) => name === 'record_redirect_visit')?.[1]?.p_country,
    ).toBe('CH');
  });
  it('does not disclose destinations or record invalid password attempts, and strips password query values', async () => {
    const run = runtime();
    vi.stubGlobal('crypto', webcrypto);
    run.state.settings.password_hash = await hashLinkPassword('fixture password');
    vi.unstubAllGlobals();
    const denied = await run.invoke('GET', 'pw=wrong');
    expect(denied.status).toBe(401);
    expect(denied.headers.has('Location')).toBe(false);
    expect(await denied.text()).not.toContain('example.com');
    expect(run.rpc).not.toHaveBeenCalled();
    const allowed = await run.invoke('GET', 'pw=fixture+password&utm_source=qr');
    expect(allowed.status).toBe(302);
    expect(allowed.headers.get('Location')).not.toContain('pw=');
    expect(run.rpc.mock.calls[0][1]?.p_query).toBe('utm_source=qr');
    expect((await run.invoke('POST', 'utm_source=qr', 'password=fixture+password')).status).toBe(
      302,
    );
  });
  it('uses live state instead of a stale cached rule and never tracks expired fallbacks', async () => {
    const run = runtime();
    expect((await run.invoke()).status).toBe(302);
    run.state.link.is_enabled = false;
    expect((await run.invoke()).status).toBe(404);
    run.state.link.is_enabled = true;
    run.state.link.end_at = '2000-01-01T00:00:00Z';
    run.state.settings.policy = { expired_target: '/expired' };
    expect((await run.invoke()).headers.get('Location')).toBe(
      'https://queer.guide/expired?utm_source=qr',
    );
    expect(run.rpc).toHaveBeenCalledTimes(1);
  });
  it('fails closed on missing policy data and on an atomically exhausted quota', async () => {
    const run = runtime();
    run.state.failed = true;
    expect((await run.invoke()).status).toBe(503);
    run.state.failed = false;
    run.state.quota = false;
    expect((await run.invoke()).status).toBe(410);
  });
});
