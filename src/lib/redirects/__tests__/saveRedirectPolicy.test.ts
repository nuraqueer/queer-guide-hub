import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import ts from 'typescript';
import { describe, expect, it, vi } from 'vitest';

function runtime() {
  const root = '../../../../supabase/functions/';
  const shared = readFileSync(
    new URL(root + '_shared/link-policy.ts', import.meta.url),
    'utf8',
  ).replace(/^export\s+/gm, '');
  const source = readFileSync(
    new URL(root + 'save-redirect-policy/index.ts', import.meta.url),
    'utf8',
  ).replace(/^import .*;\s*$/gm, '');
  const code = ts.transpileModule(shared + '\n' + source, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
  }).outputText;
  let handler: (req: Request) => Promise<Response>;
  const state = { authenticated: true, admin: true };
  const save = vi.fn(async (_name: string, args: Record<string, unknown>) => ({
    data: { policy: args.p_policy, has_password: !!args.p_password_hash },
    error: null,
  }));
  const identity = {
    auth: {
      getUser: vi.fn(async () => ({
        data: { user: state.authenticated ? { id: 'admin' } : null },
        error: null,
      })),
    },
    rpc: vi.fn(async () => ({ data: state.admin, error: null })),
  };
  const clients = vi.fn((_url: string, key: string) =>
    key === 'service' ? { rpc: save } : identity,
  );
  new Function('Deno', 'createClient', 'crypto', code)(
    {
      env: { get: (key: string) => (key === 'SUPABASE_SERVICE_ROLE_KEY' ? 'service' : 'fixture') },
      serve: (fn: typeof handler) => {
        handler = fn;
      },
    },
    clients,
    webcrypto,
  );
  return {
    state,
    save,
    clients,
    identity,
    invoke: (body: unknown, authorization: string | null = 'Bearer signed-user-token') =>
      handler(
        new Request('https://fixture.supabase.co/functions/v1/save-redirect-policy', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...(authorization ? { Authorization: authorization } : {}),
          },
          body: JSON.stringify(body),
        }),
      ),
  };
}
const policyBody = {
  redirect_id: '00000000-0000-4000-8000-000000000001',
  policy: { device_targets: { ios: 'https://apps.apple.com/app/example' } },
};
describe('policy-saving authorization boundary', () => {
  it('rejects absent or invalid identity before accessing privileged storage', async () => {
    const run = runtime();
    expect((await run.invoke(policyBody, null)).status).toBe(401);
    run.state.authenticated = false;
    expect((await run.invoke(policyBody)).status).toBe(401);
    expect(run.save).not.toHaveBeenCalled();
    expect(run.identity.auth.getUser).toHaveBeenCalledWith('signed-user-token');
    expect(run.clients.mock.calls.some(([, key]) => key === 'service')).toBe(false);
  });
  it('denies non-admins and rejects private targets without a write', async () => {
    const run = runtime();
    run.state.admin = false;
    expect((await run.invoke(policyBody)).status).toBe(403);
    run.state.admin = true;
    expect(
      (await run.invoke({ ...policyBody, policy: { expired_target: 'http://127.0.0.1/private' } }))
        .status,
    ).toBe(400);
    expect(run.save).not.toHaveBeenCalled();
  });
  it('stores salted hashes only, keeps an existing password by default, and supports explicit removal', async () => {
    const run = runtime();
    const response = await run.invoke({ ...policyBody, password: 'fixture-secret' });
    expect(response.status).toBe(200);
    expect(await response.text()).not.toContain('fixture-secret');
    const saved = run.save.mock.calls[0][1];
    expect(saved.p_password_hash).toMatchObject({ algorithm: 'PBKDF2-SHA256', iterations: 600000 });
    expect(JSON.stringify(saved)).not.toContain('fixture-secret');
    expect(saved.p_change_password).toBe(true);
    await run.invoke(policyBody);
    expect(run.save.mock.calls[1][1].p_change_password).toBe(false);
    await run.invoke({ ...policyBody, remove_password: true });
    expect(run.save.mock.calls[2][1]).toMatchObject({
      p_change_password: true,
      p_password_hash: null,
    });
  });
});
