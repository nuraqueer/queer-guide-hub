import { afterEach, describe, expect, it, vi } from 'vitest';
import { onRequest } from '../api/redirects/[[path]]';
afterEach(() => vi.unstubAllGlobals());
const invoke = (method = 'POST') =>
  onRequest({
    request: new Request('https://queer.guide/api/redirects/track/sale', {
      method,
      headers: { Authorization: 'Bearer server-fixture', 'Content-Type': 'application/json' },
      ...(method === 'POST' ? { body: '{"eventId":"fixture"}' } : {}),
    }),
    params: { path: ['track', 'sale'] },
    env: { SUPABASE_URL: 'https://fixture.supabase.co', SUPABASE_ANON_KEY: 'public-fixture' },
  } as never);
describe('branded Redirects API proxy', () => {
  it('passes server credentials to the owned endpoint, preserves status and prevents caching', async () => {
    const fetcher = vi.fn(async () => new Response('{"error":"duplicate"}', { status: 409 }));
    vi.stubGlobal('fetch', fetcher);
    const response = await invoke();
    expect(response.status).toBe(409);
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    const [url, options] = fetcher.mock.calls[0] as unknown as [URL, RequestInit];
    expect(url.href).toBe('https://fixture.supabase.co/functions/v1/redirect-api/track/sale');
    expect(new Headers(options.headers).get('Authorization')).toBe('Bearer server-fixture');
    expect(options.redirect).toBe('manual');
  });
  it('rejects unsupported methods and reports upstream failures without following redirects', async () => {
    expect((await invoke('PUT')).status).toBe(405);
    vi.stubGlobal(
      'fetch',
      vi.fn(
        async () =>
          new Response(null, { status: 302, headers: { Location: 'https://example.com' } }),
      ),
    );
    expect((await invoke()).status).toBe(502);
  });
});
