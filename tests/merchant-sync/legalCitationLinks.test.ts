import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

beforeEach(() => {
  vi.resetModules();
  vi.stubEnv('SUPABASE_URL', 'https://fixture.example');
  vi.stubEnv('SUPABASE_SERVICE_ROLE_KEY', 'fixture');
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.spyOn(process, 'exit').mockImplementation((code) => { throw new Error(`exit:${code}`); });
});
afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});

function fixture(status: number | 'network', finalPath = '/citation') {
  vi.stubGlobal('fetch', vi.fn(async (url: string) => {
    if (url.includes('/rest/v1/tag_sources')) {
      return Response.json([{ source_url: 'https://law.example/citation', unified_tags: { slug: 'test' } }]);
    }
    if (status === 'network') throw new Error('connection reset');
    const response = new Response(null, { status });
    Object.defineProperty(response, 'url', { value: `https://law.example${finalPath}` });
    return response;
  }));
}

describe('legal citation scheduled gate', () => {
  it.each(['network', 400, 401, 403, 405, 429, 451, 500, 503] as const)('reports %s as unverifiable without declaring the document dead', async (status) => {
    fixture(status);
    await import('../../scripts/check-legal-citation-links.mjs');
    expect(console.log).toHaveBeenCalledWith(expect.stringContaining('1 unverifiable, 0 dead'));
    expect(process.exit).not.toHaveBeenCalled();
  });

  it.each([404, 410])('still fails the gate for a confirmed HTTP %s', async (status) => {
    fixture(status);
    await expect(import('../../scripts/check-legal-citation-links.mjs')).rejects.toThrow('exit:1');
    expect(console.log).toHaveBeenCalledWith(expect.stringContaining('0 unverifiable, 1 dead'));
  });

  it('fails a soft-404 that answers HTTP200 on an error page', async () => {
    fixture(200, '/error');
    await expect(import('../../scripts/check-legal-citation-links.mjs')).rejects.toThrow('exit:1');
  });

  it('accepts a verified document', async () => {
    fixture(200);
    await import('../../scripts/check-legal-citation-links.mjs');
    expect(console.log).toHaveBeenCalledWith(expect.stringContaining('1 ok, 0 unverifiable, 0 dead'));
  });
});
