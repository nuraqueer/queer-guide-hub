import sharp from 'sharp';
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
  const policy = readFileSync(
    new URL(root + '_shared/link-policy.ts', import.meta.url),
    'utf8',
  ).replace(/^export\s+/gm, '');
  const links = readFileSync(new URL(root + '_shared/redirect-links.ts', import.meta.url), 'utf8')
    .replace(/^import .*;\s*$/gm, '')
    .replace(/^export\s+/gm, '');
  const presentation = readFileSync(
    new URL(root + '_shared/redirect-presentation.ts', import.meta.url),
    'utf8',
  ).replace(/^export\s+/gm, '');
  const policyApi = readFileSync(
    new URL(root + '_shared/redirect-policy-api.ts', import.meta.url),
    'utf8',
  )
    .replace(/^import .*;\s*$/gm, '')
    .replace(/^export\s+/gm, '');
  const code = ts.transpileModule(
    shared +
      '\n' +
      analytics +
      '\n' +
      policy +
      '\n' +
      links +
      '\n' +
      presentation +
      '\n' +
      policyApi +
      '\n' +
      source,
    {
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
    },
  ).outputText;
  let handler: (req: Request) => Promise<Response>;
  const state = {
    admin: true,
    validIdentity: true,
    validToken: true,
    allowedIds: ['00000000-0000-4000-8000-000000000002'] as string[] | null,
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
          data: state.conversionError
            ? null
            : name === 'redirect_workspace_resource'
              ? { id: 'resource', name: 'API folder', data: [], count: 0, nextCursor: null }
              : name === 'redirect_management_list'
                ? {
                    data: [{ id: 'link-id', slug: 'pride', target: '/events' }],
                    count: 1,
                    nextCursor: null,
                  }
                : name === 'redirect_management_mutate'
                  ? (_args?.p_operations as Array<{ operation: string }>).map((op) =>
                      op.operation === 'delete'
                        ? { deleted: true, id: 'link-id' }
                        : {
                            created: ['create', 'upsert'].includes(op.operation),
                            link: { id: 'link-id', slug: 'pride', target: '/events' },
                          },
                    )
                  : { id: 'conversion', duplicate: false },
          error: state.conversionError,
        },
  );
  const generate = vi.fn(async () => ({
    title: 'Generated title',
    description: 'Generated description',
  }));
  const upload = vi.fn(async () => ({ error: null })),
    remove = vi.fn(async () => ({ error: null }));
  const storage = {
    from: () => ({
      upload,
      remove,
      getPublicUrl: (key: string) => ({
        data: {
          publicUrl:
            'https://fixture.supabase.co/storage/v1/object/public/redirect-previews/' + key,
        },
      }),
    }),
  };
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
  new Function(
    'Deno',
    'createClient',
    'crypto',
    'generateRedirectPreview',
    'isLlmConfigured',
    code,
  )(
    {
      env: {
        get: (name: string) => (name === 'SUPABASE_SERVICE_ROLE_KEY' ? 'service' : 'fixture'),
      },
      serve: (fn: typeof handler) => {
        handler = fn;
      },
    },
    (_url: string, key: string) => (key === 'service' ? { rpc, from, storage } : identity),
    webcrypto,
    generate,
    () => true,
  );
  return {
    state,
    generate,
    rpc,
    from,
    getUser,
    upload,
    remove,
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
  it('validates public presentation settings and bounds real image uploads before storage', async () => {
    const run = runtime(),
      token = 'qg_redirect_' + 'a'.repeat(64);
    expect(
      (
        await run.invoke(
          '/links/' + click + '/presentation',
          { preview: { title: 'Community', video: 'https://example.com/a.mp4' }, cloaked: true },
          token,
          'PATCH',
        )
      ).status,
    ).toBe(200);
    expect(
      (
        await run.invoke(
          '/links/' + click + '/presentation',
          { preview: { title: 'x'.repeat(121) } },
          token,
          'PATCH',
        )
      ).status,
    ).toBe(400);
    expect(
      (
        await run.invoke(
          '/links/' + click + '/preview-image',
          { image: Buffer.from('<svg/>').toString('base64') },
          token,
        )
      ).status,
    ).toBe(400);
    expect(run.upload).not.toHaveBeenCalled();
    const bytes = await sharp({
      create: { width: 1200, height: 630, channels: 3, background: '#ffeecc' },
    })
      .png()
      .toBuffer();
    const uploaded = await run.invoke(
      '/links/' + click + '/preview-image',
      { image: bytes.toString('base64') },
      token,
    );
    expect(uploaded.status).toBe(201);
    expect(run.upload).toHaveBeenCalledWith(
      expect.stringMatching(/\.png$/),
      expect.any(Uint8Array),
      expect.objectContaining({ contentType: 'image/png', upsert: false }),
    );
    const body = await uploaded.json();
    expect(body.width).toBe(1200);
    expect(body.height).toBe(630);
    expect(body.image).toContain('/redirect-previews/');
    run.upload.mockClear();
    run.state.conversionError = { code: '42501', message: 'Outside link scope' };
    expect(
      (
        await run.invoke(
          '/links/' + click + '/preview-image',
          { image: bytes.toString('base64') },
          token,
        )
      ).status,
    ).toBe(403);
    expect(run.upload).not.toHaveBeenCalled();
  });
  it('enforces independent workspace permissions and denies selected-link workspace credentials', async () => {
    const run = runtime(),
      token = 'qg_redirect_' + 'a'.repeat(64);
    expect((await run.invoke('/folders', { name: 'Campaigns' }, token)).status).toBe(403);
    run.state.allowedIds = null;
    expect((await run.invoke('/folders', { name: 'Campaigns' }, token)).status).toBe(201);
    expect(
      run.rpc.mock.calls.find(([name]) => name === 'authenticate_redirect_api_token')?.[1]?.p_scope,
    ).toBe('workspace:write');
    expect((await run.invoke('/tags', { name: 'Bad', color: 'neon' }, token)).status).toBe(400);
    expect(
      (await run.invoke('/templates', { name: 'Bad', parameters: { pw: 'secret' } }, token)).status,
    ).toBe(400);
    expect((await run.invoke('/folders?limit=101', undefined, token, 'GET')).status).toBe(400);
    expect((await run.invoke('/folders', undefined, token, 'GET')).status).toBe(200);
    expect(
      (await run.invoke('/folders/' + click, { description: 'Edited' }, token, 'PATCH')).status,
    ).toBe(200);
    expect((await run.invoke('/folders/' + click, undefined, token, 'GET')).status).toBe(200);
    expect((await run.invoke('/folders/' + click, undefined, token, 'DELETE')).status).toBe(200);
  });
  it('requires management scopes, preserves verified actor identity and forwards validated create/upsert/bulk operations', async () => {
    const run = runtime(),
      token = 'qg_redirect_' + 'a'.repeat(64);
    const created = await run.invoke(
      '/links',
      { target: '/events', tagIds: [click, click] },
      token,
    );
    expect(created.status).toBe(201);
    expect(
      run.rpc.mock.calls.find(([name]) => name === 'authenticate_redirect_api_token')?.[1]?.p_scope,
    ).toBe('links:write');
    expect(
      run.rpc.mock.calls.find(([name]) => name === 'redirect_management_mutate')?.[1],
    ).toMatchObject({
      p_token_id: 'token-id',
      p_actor_id: null,
      p_operations: [{ operation: 'create', data: { target: '/events', tagIds: [click] } }],
    });
    run.rpc.mockClear();
    expect(
      (
        await run.invoke(
          '/links/upsert',
          { slug: 'pride', target: '/events' },
          'signed-user',
          'PUT',
        )
      ).status,
    ).toBe(201);
    expect(
      run.rpc.mock.calls.find(([name]) => name === 'redirect_management_mutate')?.[1]?.p_actor_id,
    ).toBe('00000000-0000-4000-8000-000000000001');
    expect(
      (await run.invoke('/links/' + click, { target: '/updated' }, token, 'PATCH')).status,
    ).toBe(200);
    expect(
      (await run.invoke('/links/bulk', { operations: [{ operation: 'delete', id: click }] }, token))
        .status,
    ).toBe(200);
    run.state.validToken = false;
    expect((await run.invoke('/links', undefined, token, 'GET')).status).toBe(403);
    run.state.admin = false;
    expect((await run.invoke('/links', { target: '/events' })).status).toBe(403);
  });
  it('validates closed link inputs and returns count/list/detail reads with read scope', async () => {
    const run = runtime(),
      token = 'qg_redirect_' + 'a'.repeat(64);
    expect((await run.invoke('/links', { target: 'http://127.0.0.1/' })).status).toBe(400);
    expect((await run.invoke('/links', { target: '/go/another-link' })).status).toBe(400);
    expect((await run.invoke('/links', { target: '/events', created_by: 'spoofed' })).status).toBe(
      400,
    );
    expect(
      (await run.invoke('/links/bulk', { operations: [{ operation: 'delete', id: 'invalid' }] }))
        .status,
    ).toBe(400);
    expect(run.rpc).not.toHaveBeenCalled();
    expect((await run.invoke('/links?limit=101', undefined, token, 'GET')).status).toBe(400);
    const result = await run.invoke('/links/count', undefined, token, 'GET');
    expect(await result.json()).toEqual({ count: 1 });
    expect(
      run.rpc.mock.calls.find(([name]) => name === 'authenticate_redirect_api_token')?.[1]?.p_scope,
    ).toBe('links:read');
    expect(
      run.rpc.mock.calls.find(([name]) =>
        name === 'redirect_workspace_resource'
          ? { id: 'resource', name: 'API folder', data: [], count: 0, nextCursor: null }
          : name === 'redirect_management_list',
      )?.[1]?.p_limit,
    ).toBe(0);
    expect((await run.invoke('/links/' + click, undefined, token, 'GET')).status).toBe(200);
    run.state.conversionError = { code: '23503', message: 'Unknown tag' };
    expect((await run.invoke('/links', { target: '/events' }, token)).status).toBe(400);
    run.state.conversionError = { code: '42501', message: 'Outside scope' };
    expect((await run.invoke('/links/' + click, undefined, token, 'DELETE')).status).toBe(403);
  });
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
  it('uses verified workspace membership for non-admin sessions and rechecks analytics in SQL', async () => {
    const run = runtime();
    run.state.admin = false;
    const memberId = '00000000-0000-4000-8000-000000000009';
    const base = run.rpc.getMockImplementation()!;
    run.rpc.mockImplementation(async (name, args) =>
      name === 'redirect_session_principal'
        ? { data: { id: memberId, duplicate: false }, error: null }
        : base(name, args),
    );
    expect((await run.invoke('/links', undefined, 'signed-user', 'GET')).status).toBe(200);
    expect(run.rpc).toHaveBeenCalledWith('redirect_session_principal', {
      p_user_id: '00000000-0000-4000-8000-000000000001',
      p_scope: 'links:read',
    });
    expect(run.rpc).toHaveBeenCalledWith(
      'redirect_management_list',
      expect.objectContaining({ p_token_id: memberId }),
    );
    expect((await run.invoke('/analytics', undefined, 'signed-user', 'GET')).status).toBe(200);
    expect(run.rpc).toHaveBeenCalledWith(
      'redirect_scoped_analytics',
      expect.objectContaining({ p_token_id: memberId, p_action: 'report' }),
    );
    expect((await run.invoke('/members', undefined, 'signed-user', 'GET')).status).toBe(403);
    expect((await run.invoke('/track/lead', lead, 'signed-user')).status).toBe(403);
  });
  it('fails closed on an absent membership instead of treating it as an administrator', async () => {
    const run = runtime();
    run.state.admin = false;
    run.rpc.mockResolvedValue({ data: null, error: null });
    expect((await run.invoke('/links', undefined, 'signed-user', 'GET')).status).toBe(403);
    expect(run.rpc).not.toHaveBeenCalledWith('redirect_management_list', expect.anything());
  });
  it('passes access-management principals to SQL and rejects selected-link keys', async () => {
    const run = runtime(),
      folder = '00000000-0000-4000-8000-000000000005';
    expect(
      (
        await run.invoke(
          '/folders/' + folder + '/access',
          { defaultPermission: 'none' },
          'signed-user',
          'PATCH',
        )
      ).status,
    ).toBe(200);
    expect(run.rpc).toHaveBeenCalledWith('redirect_folder_access', {
      p_folder: folder,
      p_values: { defaultPermission: 'none' },
      p_token_id: null,
    });
    run.rpc.mockClear();
    expect(
      (
        await run.invoke(
          '/folders/' + folder + '/access',
          undefined,
          'qg_redirect_' + 'a'.repeat(64),
          'GET',
        )
      ).status,
    ).toBe(403);
    expect(run.rpc).not.toHaveBeenCalledWith('redirect_folder_access', expect.anything());
  });
  it('accepts workspace-scoped machine keys for folder ownership checks in SQL', async () => {
    const run = runtime();
    run.state.allowedIds = null;
    const folder = '00000000-0000-4000-8000-000000000005';
    expect(
      (
        await run.invoke(
          '/folders/' + folder + '/access',
          { defaultPermission: 'view' },
          'qg_redirect_' + 'a'.repeat(64),
          'PATCH',
        )
      ).status,
    ).toBe(200);
    expect(run.rpc).toHaveBeenCalledWith(
      'authenticate_redirect_api_token',
      expect.objectContaining({ p_scope: 'workspace:write' }),
    );
    expect(run.rpc).toHaveBeenCalledWith('redirect_folder_access', {
      p_folder: folder,
      p_values: { defaultPermission: 'view' },
      p_token_id: 'token-id',
    });
  });
  it('scopes variant metrics to the verified credential and rejects machine session discovery', async () => {
    const run = runtime(),
      id = '00000000-0000-4000-8000-000000000005',
      token = 'qg_redirect_' + 'a'.repeat(64);
    expect((await run.invoke('/links/' + id + '/variants', undefined, token, 'GET')).status).toBe(
      200,
    );
    expect(run.rpc).toHaveBeenCalledWith('redirect_scoped_variant_performance', {
      p_redirect_id: id,
      p_token_id: 'token-id',
    });
    expect((await run.invoke('/session', undefined, token, 'GET')).status).toBe(403);
  });
  it('applies read scope and credential link boundaries to analytics and paginated activity', async () => {
    const run = runtime(),
      token = 'qg_redirect_' + 'a'.repeat(64);
    expect((await run.invoke('/analytics', undefined, token, 'GET')).status).toBe(200);
    expect(run.rpc.mock.calls[0][1]).toMatchObject({ p_scope: 'events:read' });
    expect(run.rpc.mock.calls[1]).toMatchObject([
      'redirect_scoped_analytics',
      { p_action: 'report', p_token_id: 'token-id', p_filters: {} },
    ]);
    expect((await run.invoke('/events?limit=101', undefined, token, 'GET')).status).toBe(400);
    expect((await run.invoke('/events?limit=50', undefined, token, 'GET')).status).toBe(200);
    expect(run.rpc.mock.calls.at(-1)).toMatchObject([
      'redirect_scoped_analytics',
      { p_action: 'events', p_token_id: 'token-id', p_limit: 50 },
    ]);
    run.state.validToken = false;
    expect((await run.invoke('/analytics', undefined, token, 'GET')).status).toBe(403);
    run.state.admin = false;
    expect((await run.invoke('/analytics', undefined, 'signed-user', 'GET')).status).toBe(403);
  });
});

describe('preview generation API', () => {
  it('checks scope before reserving spend and rechecks access before returning a draft', async () => {
    const app = runtime();
    app.rpc.mockImplementation(
      async (name) =>
        ({
          data:
            name === 'reserve_redirect_preview'
              ? { target: 'https://example.com', retryAfter: 0 }
              : {},
          error: null,
        }) as never,
    );
    const response = await app.invoke('/links/' + click + '/preview-generate', {});
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      title: 'Generated title',
      description: 'Generated description',
    });
    expect(app.rpc.mock.calls.map((call) => call[0])).toEqual([
      'redirect_presentation',
      'reserve_redirect_preview',
      'redirect_presentation',
    ]);
    expect(app.generate).toHaveBeenCalledWith('https://example.com', 'fixture', click);
  });
  it('does not contact providers after authorization or rate-limit failures', async () => {
    const app = runtime();
    app.rpc.mockResolvedValue({
      data: null,
      error: { code: '42501', message: 'Outside scope' },
    } as never);
    expect((await app.invoke('/links/' + click + '/preview-generate', {})).status).toBe(403);
    expect(app.generate).not.toHaveBeenCalled();
    app.rpc.mockImplementation(
      async (name) =>
        ({
          data: name === 'reserve_redirect_preview' ? { retryAfter: 180 } : {},
          error: null,
        }) as never,
    );
    const response = await app.invoke('/links/' + click + '/preview-generate', {});
    expect(response.status).toBe(429);
    expect(response.headers.get('Retry-After')).toBe('180');
    expect(app.generate).not.toHaveBeenCalled();
  });
  it('rejects target overrides and discards results when credentials are revoked during generation', async () => {
    const app = runtime();
    expect(
      (await app.invoke('/links/' + click + '/preview-generate', { target: 'https://example.com' }))
        .status,
    ).toBe(400);
    app.rpc
      .mockResolvedValueOnce({ data: {}, error: null } as never)
      .mockResolvedValueOnce({
        data: { target: 'https://example.com', retryAfter: 0 },
        error: null,
      } as never)
      .mockResolvedValueOnce({ data: null, error: { code: '42501', message: 'Revoked' } } as never);
    expect((await app.invoke('/links/' + click + '/preview-generate', {})).status).toBe(403);
  });
});

describe('bulk import payload size', () => {
  it('accepts a legitimate hundred-row batch over the single-link 64 KB limit', async () => {
    const app = runtime();
    const operations = Array.from({ length: 100 }, (_, index) => ({
      operation: 'create',
      data: {
        slug: 'import-' + index,
        target: 'https://example.com/?description=' + 'x'.repeat(1000),
      },
    }));
    const response = await app.invoke('/links/bulk', { operations });
    expect(response.status).toBe(200);
    expect((await response.json()).data).toHaveLength(100);
  });
});

describe('scoped policy endpoints', () => {
  it('gets and patches only through the scoped policy RPC', async () => {
    const app = runtime();
    app.rpc.mockResolvedValue({
      data: { policy: { track_conversions: true }, hasPassword: false },
      error: null,
    } as never);
    const get = await app.invoke('/links/' + click + '/policy', undefined, 'signed-user', 'GET');
    expect(get.status).toBe(200);
    const patch = await app.invoke(
      '/links/' + click + '/policy',
      { policy: { geo_targets: null } },
      'signed-user',
      'PATCH',
    );
    expect(patch.status).toBe(200);
    expect(app.rpc).toHaveBeenLastCalledWith('redirect_policy_resource', {
      p_redirect_id: click,
      p_action: 'patch',
      p_patch: { geo_targets: null },
      p_password_hash: null,
      p_change_password: false,
      p_token_id: null,
    });
  });
  it('reserves before hashing and never forwards plaintext to SQL', async () => {
    const app = runtime();
    app.rpc.mockImplementation(
      async (name) =>
        ({
          data: name === 'reserve_redirect_policy_password' ? 0 : { policy: {}, hasPassword: true },
          error: null,
        }) as never,
    );
    const response = await app.invoke(
      '/links/' + click + '/policy',
      { password: 'fixture-password' },
      'signed-user',
      'PATCH',
    );
    expect(response.status).toBe(200);
    expect(app.rpc.mock.calls.map((call) => call[0])).toEqual([
      'reserve_redirect_policy_password',
      'redirect_policy_resource',
    ]);
    const args = app.rpc.mock.calls[1][1]!;
    expect(args.p_password_hash).toMatchObject({ algorithm: 'PBKDF2-SHA256', iterations: 600000 });
    expect(JSON.stringify(args)).not.toContain('fixture-password');
  });
  it('returns retry-after without hashing or writing when password budget is exhausted', async () => {
    const app = runtime();
    app.rpc.mockResolvedValue({ data: 123, error: null } as never);
    const response = await app.invoke(
      '/links/' + click + '/policy',
      { password: 'fixture-password' },
      'signed-user',
      'PATCH',
    );
    expect(response.status).toBe(429);
    expect(response.headers.get('Retry-After')).toBe('123');
    expect(app.rpc.mock.calls.map((call) => call[0])).toEqual(['reserve_redirect_policy_password']);
  });
  it('removes passwords explicitly and rejects unrecognized fields before writes', async () => {
    const app = runtime();
    app.rpc.mockResolvedValue({ data: { policy: {}, hasPassword: false }, error: null } as never);
    expect(
      (
        await app.invoke(
          '/links/' + click + '/policy',
          { password_hash: 'bad' },
          'signed-user',
          'PATCH',
        )
      ).status,
    ).toBe(400);
    expect(app.rpc).not.toHaveBeenCalled();
    expect(
      (await app.invoke('/links/' + click + '/policy', { password: null }, 'signed-user', 'PATCH'))
        .status,
    ).toBe(200);
    expect(app.rpc.mock.calls[0][1]).toMatchObject({
      p_change_password: true,
      p_password_hash: null,
    });
  });
});

describe('policy revocation during password hashing', () => {
  it('honors the final database authorization check after a reservation succeeds', async () => {
    const app = runtime();
    app.rpc.mockResolvedValueOnce({ data: 0, error: null } as never).mockResolvedValueOnce({
      data: null,
      error: { code: '42501', message: 'Credential revoked' },
    } as never);
    const response = await app.invoke(
      '/links/' + click + '/policy',
      { password: 'fixture-password' },
      'signed-user',
      'PATCH',
    );
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: 'Credential revoked' });
  });
});
