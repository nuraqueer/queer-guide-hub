import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ client: vi.fn(), consume: vi.fn() }));
vi.mock('../../supabase/functions/_shared/supabase-client.ts', () => ({
  getServiceClient: mocks.client,
  getCorsHeaders: () => ({}),
  corsResponse: () => new Response(null),
  requireInternalOrAdmin: async () => null,
}));
vi.mock('../../supabase/functions/_shared/llm-budget.ts', () => ({ consumeLlmBudget: mocks.consume }));
vi.mock('../../supabase/functions/_shared/marketplace-description.ts', () => ({
  marketplaceDescriptionFromRaw: () => null,
}));

let handler: (request: Request) => Promise<Response>;
let clock = 0;
let providerLatency = 0;
let provider: ReturnType<typeof vi.fn>;
const rows = Array.from({ length: 3 }, (_, index) => ({
  id: `listing-${index}`, title: 'Cotton shirt',
  description: 'A cotton shirt with a printed rainbow design.', description_i18n: {},
}));

beforeAll(async () => {
  const environment: Record<string, string> = { CF_ACCOUNT_ID: 'test', CF_AI_API_TOKEN: 'test' };
  vi.stubGlobal('Deno', {
    env: { get: (key: string) => environment[key] },
    serve: (callback: typeof handler) => { handler = callback; },
  });
  await import('../../supabase/functions/marketplace-description-enhance/index.ts');
});

beforeEach(() => {
  clock = 0;
  providerLatency = 0;
  vi.spyOn(Date, 'now').mockImplementation(() => clock);
  mocks.consume.mockReset().mockResolvedValue({ allowed: true, cap: 500 });
  const query = {
    select: () => query, eq: () => query, not: () => query, order: () => query,
    limit: async () => ({ data: rows, error: null }),
  };
  mocks.client.mockReturnValue({ from: () => query });
  provider = vi.fn(async () => {
    clock += providerLatency;
    return Response.json({ result: { response: {
      description: 'A cotton shirt with a printed rainbow design.', source_lang: 'en',
    } } });
  });
  vi.stubGlobal('fetch', provider);
});

afterEach(() => { vi.restoreAllMocks(); });
afterAll(() => { vi.unstubAllGlobals(); });

async function run() {
  const response = await handler(new Request('https://example.test/enhance', {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ merchant_domain: 'example.test', dry_run: true }),
  }));
  expect(response.status).toBe(200);
  return response.json();
}

describe('description worker quota and deadline', () => {
  it('charges only the call made before the time budget defers the other rows', async () => {
    providerLatency = 30_000;
    const result = await run();
    expect(provider).toHaveBeenCalledTimes(1);
    expect(mocks.consume).toHaveBeenCalledTimes(1);
    expect(mocks.consume.mock.calls[0][2]).toBe(1);
    expect(result).toMatchObject({ success: true, items_changed: 1, deferred: 2 });
  });

  it('consumes one quota unit per actual inference in a completed batch', async () => {
    const result = await run();
    expect(provider).toHaveBeenCalledTimes(3);
    expect(mocks.consume.mock.calls.map(call => call[2])).toEqual([1, 1, 1]);
    expect(result).toMatchObject({ success: true, items_changed: 3, deferred: 0 });
  });

  it('keeps partial progress and reports intentional daily-cap deferral', async () => {
    mocks.consume.mockResolvedValueOnce({ allowed: true, cap: 500 })
      .mockResolvedValue({ allowed: false, cap: 500 });
    const result = await run();
    expect(provider).toHaveBeenCalledTimes(1);
    expect(mocks.consume.mock.calls.map(call => call[2])).toEqual([1, 1]);
    expect(result).toMatchObject({
      success: true, items_changed: 1, items_terminal: 3, items_skipped: 2,
      deferred: 2, message: 'llm_budget_deferred', daily_cap: 500,
    });
  });

  it('makes no inference when the daily cap is already exhausted', async () => {
    mocks.consume.mockResolvedValue({ allowed: false, cap: 500 });
    const result = await run();
    expect(provider).not.toHaveBeenCalled();
    expect(result).toMatchObject({
      success: true, items_changed: 0, items_terminal: 3, deferred: 3,
      message: 'llm_budget_deferred',
    });
  });
});
