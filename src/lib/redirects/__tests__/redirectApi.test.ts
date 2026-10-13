import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import ts from 'typescript';
import { describe, expect, it, vi } from 'vitest';
function runtime() {
  const root = '../../../../supabase/functions/';
  const shared = readFileSync(
    new URL(root + '_shared/redirect-api.ts', import.meta.url),
    'utf8',
  ).replace(/^export\s+/gm, '');
  const source = readFileSync(
    new URL(root + 'redirect-api/index.ts', import.meta.url),
    'utf8',
  ).replace(/^import .*;\s*$/gm, '');
  const analytics = readFileSync(
    new URL(root + '_shared/redirect-analytics.ts', import.meta.url),
    'utf8',
  )
    .replace(/^import .*;\s*$/gm, '')
    .replace(/^export\s+/gm, '');
  const code = ts.transpileModule(shared + '\n' + analytics + '\n' + source, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
  }).outputText;
  let handler: (req: Request) => Promise<Response>;
  const state = {
    admin: true,
    validIdentity: true,
    validToken: true,
    allowedIds: ['00000000-0000-4000-8000-000000000002'],
    confirmed: true,
    conversionError: null as { code: string; message: string } | null,
  };
  const user = {
    id: '00000000-0000-4000-8000-000000000001',
    created_at: '2026-10-13T09:00:00Z',
    confirmed_at: '2026-10-13T09:01:00Z',
    is_anonymous: false,
    user_metadata: { role: 'admin' },
  };
  const rpc = vi.fn(async (name: string, _args?: Record<string, unknown>) =>
    name === 'authenticate_redirect_api_token'
      ? {
          data: state.validToken ? { id: 'token-id', redirect_ids: state.allowedIds } : null,
          error: null,
        }
      : {
          data: state.conversionError ? null : { id: 'conversion', duplicate: false },
          error: state.conversionError,
        },
  );
  const from = vi.fn(() => {
    const query = {
      select: () => query,
      order: () => query,
      range: () => ({ data: [], count: 0, error: null }),
      eq: () => query,
      in: () => query,
      is: () => ({ data: [{ id: 'token-id', redirect_ids: state.allowedIds }], error: null }),
      insert: vi.fn((values: Record<string, unknown>) => ({
        select: () => ({
          single: async () => ({ data: { id: 'token-id', prefix: values.prefix }, error: null }),
        }),
      })),
      update: () => query,
    };
    return query;
  });
  const getUser = vi.fn(async () => ({
    data: {
      user: state.validIdentity
        ? { ...user, confirmed_at: state.confirmed ? user.confirmed_at : undefined }
        : null,
    },
    error: null,
  }));
  const identity = {
    auth: { getUser },
    rpc: vi.fn(async () => ({ data: state.admin, error: null })),
  };
  new Function('Deno', 'createClient', 'crypto', code)(
    {
      env: {
        get: (name: string) => (name === 'SUPABASE_SERVICE_ROLE_KEY' ? 'service' : 'fixture'),
      },
      serve: (fn: typeof handler) => {
        handler = fn;
      },
    },
    (_url: string, key: string) => (key === 'service' ? { rpc, from } : identity),
    webcrypto,
  );
  return {
    state,
    rpc,
    from,
    getUser,
    invoke: (
      path: string,
      body?: unknown,
      credential: string | null = 'signed-user',
      method = 'POST',
    ) =>
      handler(
        new Request('https://fixture.supabase.co/functions/v1/redirect-api' + path, {
          method,
          headers: {
            'Content-Type': 'application/json',
            ...(credential ? { Authorization: 'Bearer ' + credential } : {}),
          },
          ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        }),
      ),
  };
}
const click = '00000000-0000-4000-8000-000000000002',
  lead = { clickId: click, customerExternalId: 'customer-a', eventId: 'signup:a' };
describe('actual Redirects API handler', () => {
  it('denies missing/invalid identity and does not use editable user metadata for admin authority', async () => {
    const run = runtime();
    expect((await run.invoke('/track/lead', lead, null)).status).toBe(401);
    run.state.validIdentity = false;
    expect((await run.invoke('/track/lead', lead)).status).toBe(401);
    run.state.validIdentity = true;
    run.state.admin = false;
    expect((await run.invoke('/track/lead', lead)).status).toBe(403);
    expect(run.rpc).not.toHaveBeenCalled();
    expect(run.from).not.toHaveBeenCalled();
  });
  it('hashes scoped credentials, rejects missing scope/revocation and handles conflicting event retries', async () => {
    const run = runtime(),
      token = 'qg_redirect_' + 'a'.repeat(64);
    expect((await run.invoke('/track/lead', lead, token)).status).toBe(201);
    expect(run.rpc.mock.calls[0]).toMatchObject([
      'authenticate_redirect_api_token',
      { p_scope: 'conversions:write' },
    ]);
    expect(run.rpc.mock.calls[0][1]?.p_hash).not.toContain(token);
    expect(run.rpc.mock.calls[1][1]).toMatchObject({
      p_token_id: 'token-id',
      p_event: { kind: 'lead', clickId: click, eventName: 'Lead' },
    });
    run.state.validToken = false;
    expect((await run.invoke('/track/lead', lead, token)).status).toBe(403);
    run.state.validToken = true;
    run.state.conversionError = { code: '42501', message: 'Credential cannot attribute this link' };
    expect((await run.invoke('/track/lead', lead, token)).status).toBe(403);
    run.state.conversionError = {
      code: '23505',
      message: 'Event ID was already used with different data',
    };
    expect((await run.invoke('/track/lead', lead, token)).status).toBe(409);
    run.state.conversionError = { code: '08006', message: 'database offline' };
    expect((await run.invoke('/track/lead', lead, token)).status).toBe(503);
  });
  it('uses the verified account identity for native signups, without permitting browser-reported sales', async () => {
    const run = runtime();
    run.state.admin = false;
    expect((await run.invoke('/native/signup', { clickId: click })).status).toBe(201);
    expect(run.getUser).toHaveBeenCalledWith('signed-user');
    expect(run.rpc.mock.calls[0][1]).toMatchObject({
      p_registered_at: '2026-10-13T09:00:00Z',
      p_event: {
        customerExternalId: 'native:00000000-0000-4000-8000-000000000001',
        eventId: 'native:signup:00000000-0000-4000-8000-000000000001',
      },
    });
    expect(
      (await run.invoke('/native/signup', { clickId: click, customerExternalId: 'forged' })).status,
    ).toBe(400);
    expect((await run.invoke('/track/sale', { ...lead, amount: 50, currency: 'CHF' })).status).toBe(
      403,
    );
    run.state.confirmed = false;
    expect((await run.invoke('/native/signup', { clickId: click })).status).toBe(403);
  });
  it('shows a new credential only in the creation response and prevents token-based credential management', async () => {
    const run = runtime();
    const response = await run.invoke('/tokens', {
      name: 'Billing',
      expiresAt: new Date(Date.now() + 86400000).toISOString(),
    });
    expect(response.status).toBe(201);
    const created = await response.json();
    expect(created.secret).toMatch(/^qg_redirect_[a-f0-9]{64}$/);
    expect(created.token_hash).toBeUndefined();
    const list = await run.invoke('/tokens', undefined, 'signed-user', 'GET');
    expect(await list.text()).not.toContain(created.secret);
    expect(
      (await run.invoke('/tokens', undefined, 'qg_redirect_' + 'a'.repeat(64), 'GET')).status,
    ).toBe(403);
  });
  it('rejects malformed or excessive conversions before the storage RPC', async () => {
    const run = runtime();
    expect((await run.invoke('/track/sale', { ...lead, amount: -1, currency: 'CHF' })).status).toBe(
      400,
    );
    expect(
      (await run.invoke('/track/lead', { ...lead, metadata: { value: 'x'.repeat(70000) } })).status,
    ).toBe(400);
    expect(run.rpc).not.toHaveBeenCalled();
  });
  it('applies read scope and credential link boundaries to analytics and paginated activity', async () => {
    const run = runtime(),
      token = 'qg_redirect_' + 'a'.repeat(64);
    expect((await run.invoke('/analytics', undefined, token, 'GET')).status).toBe(200);
    expect(run.rpc.mock.calls[0][1]).toMatchObject({ p_scope: 'events:read' });
    expect(run.rpc.mock.calls[1]).toMatchObject([
      'redirect_analytics_report',
      { p_allowed_ids: run.state.allowedIds, p_filters: {} },
    ]);
    expect((await run.invoke('/events?limit=101', undefined, token, 'GET')).status).toBe(400);
    expect((await run.invoke('/events?limit=50', undefined, token, 'GET')).status).toBe(200);
    expect(run.rpc.mock.calls.at(-1)).toMatchObject([
      'redirect_analytics_page',
      { p_allowed_ids: run.state.allowedIds, p_limit: 50 },
    ]);
    run.state.validToken = false;
    expect((await run.invoke('/analytics', undefined, token, 'GET')).status).toBe(403);
    run.state.admin = false;
    expect((await run.invoke('/analytics', undefined, 'signed-user', 'GET')).status).toBe(403);
  });
});
