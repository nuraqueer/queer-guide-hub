import { afterEach, describe, expect, it, vi } from 'vitest';
import { webcrypto } from 'node:crypto';
import { redirectReportPage } from './redirectReportPage';
import { redirectClientIp } from '../../supabase/functions/_shared/redirect-relay';
import type { Env } from './sitemap';
const id = '00000000-0000-4000-8000-000000000001';
const path = '/share/redirect-report/' + id;
const env = {
  SUPABASE_URL: 'https://fixture.supabase.co',
  REDIRECT_RELAY_SECRET: 'fixture-secret-at-least-thirty-two-characters',
} as Env;
const data = {
  allowIndexing: true,
  title: '<script>Private? & title</script>',
  linkCount: 1,
  includeConversions: false,
  report: { totals: { clicks: 3, sales: 99 }, private: 'PRIVATE FIELD' },
};
const request = () =>
  new Request('https://queer.guide' + path, {
    headers: {
      'cf-connecting-ip': '203.0.113.4',
      authorization: 'Bearer PRIVATE SESSION',
      'x-qg-relay-ip': 'FORGED',
    },
  });
afterEach(() => vi.unstubAllGlobals());
describe('live shared-report HTML metadata', () => {
  it('uses only explicitly published title/click counts, escapes HTML and authenticates the visitor relay', async () => {
    vi.stubGlobal('crypto', webcrypto);
    const fetcher = vi.fn(async () => Response.json(data));
    vi.stubGlobal('fetch', fetcher);
    const result = await redirectReportPage(env, request(), path);
    expect(result?.indexable).toBe(true);
    expect(result?.body).toContain('&lt;script&gt;');
    expect(result?.body).not.toMatch(/PRIVATE FIELD|<script>|sales|99/);
    const options = (fetcher.mock.calls[0] as unknown as [URL, RequestInit])[1];
    expect(new Headers(options.headers).get('authorization')).toBe('Bearer qg_report_' + id);
    expect(
      await redirectClientIp(
        new Headers(options.headers),
        'report:' + id,
        env.REDIRECT_RELAY_SECRET!,
      ),
    ).toBe('203.0.113.4');
  });
  it.each([401, 404, 429, 503])(
    'fails closed with no title disclosure for HTTP %s',
    async (status) => {
      vi.stubGlobal('crypto', webcrypto);
      vi.stubGlobal(
        'fetch',
        vi.fn(async () => Response.json(data, { status })),
      );
      const result = await redirectReportPage(env, request(), path);
      expect(result).toMatchObject({ indexable: false, body: '' });
      expect(result?.meta.title).not.toContain('Private?');
    },
  );
  it('requires a strict indexing boolean and declines malformed/missing aggregates', async () => {
    vi.stubGlobal('crypto', webcrypto);
    for (const value of [
      { ...data, allowIndexing: false },
      { ...data, allowIndexing: 'true' },
      { ...data, report: {} },
    ]) {
      vi.stubGlobal(
        'fetch',
        vi.fn(async () => Response.json(value)),
      );
      expect((await redirectReportPage(env, request(), path))?.indexable).toBe(false);
    }
  });
  it('never calls the backend for localized/query variants or unrelated routes', async () => {
    const fetcher = vi.fn();
    vi.stubGlobal('fetch', fetcher);
    expect(
      await redirectReportPage(env, new Request('https://queer.guide/de' + path), path),
    ).toMatchObject({ indexable: false });
    expect(
      await redirectReportPage(
        env,
        new Request('https://queer.guide' + path + '?index=true'),
        path,
      ),
    ).toMatchObject({ indexable: false });
    expect(await redirectReportPage(env, request(), '/venues')).toBeNull();
    expect(fetcher).not.toHaveBeenCalled();
  });
});
