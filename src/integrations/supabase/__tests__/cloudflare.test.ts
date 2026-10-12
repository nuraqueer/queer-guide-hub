import { describe, it, expect, beforeEach, vi } from 'vitest';

const invokeMock = vi.hoisted(() => vi.fn());

vi.mock('../client', () => ({
  supabase: { functions: { invoke: invokeMock } },
}));

import { cloudflareAPI } from '../cloudflare';

beforeEach(() => {
  invokeMock.mockReset();
});

describe('CloudflareAPI dispatch', () => {
  it('invokes the cloudflare-api edge function with the action and params', async () => {
    invokeMock.mockResolvedValueOnce({ data: { success: true, result: {} }, error: null });
    await cloudflareAPI.getAnalytics('2026-01-01', '2026-02-01');

    expect(invokeMock).toHaveBeenCalledWith('cloudflare-api', {
      method: 'POST',
      body: { action: 'analytics', params: { since: '2026-01-01', until: '2026-02-01' } },
    });
  });

  it.each([
    ['getZoneInfo', 'zone-info'],
    ['getDNSRecords', 'dns-records'],
    ['getPageRules', 'page-rules'],
    ['getCacheStats', 'cache-stats'],
    ['getSecuritySettings', 'security-settings'],
    ['getPerformanceSettings', 'performance-settings'],
    ['getEdgeCertificates', 'edge-certificates'],
    ['getWorkers', 'workers'],
    ['getAccountInfo', 'account-info'],
  ] as const)('%s maps to action=%s', async (method, action) => {
    invokeMock.mockResolvedValueOnce({ data: { success: true, result: {} }, error: null });
    // @ts-expect-error: dynamic dispatch
    await cloudflareAPI[method]();
    const [, opts] = invokeMock.mock.calls[0];
    expect(opts.body.action).toBe(action);
  });

  it('omits since/until params when not provided', async () => {
    invokeMock.mockResolvedValueOnce({ data: { success: true, result: {} }, error: null });
    await cloudflareAPI.getBandwidthStats();
    const [, opts] = invokeMock.mock.calls[0];
    expect(opts.body.params).toEqual({});
  });
});

describe('Error handling', () => {
  it.each(['getAnalytics', 'getThreatAnalytics'] as const)(
    'rejects %s failures instead of inventing zero metrics',
    async (method) => {
      invokeMock.mockResolvedValueOnce({ data: null, error: { message: 'edge down' } });
      await expect(cloudflareAPI[method]()).rejects.toThrow('edge down');
    },
  );

  it('preserves actionable server errors from an HTTP failure', async () => {
    invokeMock.mockResolvedValueOnce({
      data: null,
      error: {
        message: 'Edge Function returned a non-2xx status code',
        context: new Response(
          JSON.stringify({ error: 'Cloudflare API token lacks Zone Settings read permission' }),
          { status: 502 },
        ),
      },
    });
    await expect(cloudflareAPI.getZoneInfo()).rejects.toThrow(
      'lacks Zone Settings read permission',
    );
  });

  it('rejects unsuccessful Cloudflare envelopes', async () => {
    invokeMock.mockResolvedValueOnce({
      data: { success: false, errors: [{ message: 'Not authorized for this zone' }] },
      error: null,
    });
    await expect(cloudflareAPI.getZoneInfo()).rejects.toThrow('Not authorized for this zone');
  });

  it('rejects empty successful responses', async () => {
    invokeMock.mockResolvedValueOnce({ data: null, error: null });
    await expect(cloudflareAPI.getZoneInfo()).rejects.toThrow('Invalid Cloudflare response');
  });

  it('re-throws errors for actions without a fallback', async () => {
    invokeMock.mockResolvedValueOnce({ data: null, error: { message: 'denied' } });
    await expect(cloudflareAPI.getZoneInfo()).rejects.toThrow('denied');
  });

  it("throws 'Failed to fetch <action>' when error has no message", async () => {
    invokeMock.mockResolvedValueOnce({ data: null, error: {} });
    await expect(cloudflareAPI.getZoneInfo()).rejects.toThrow('Failed to fetch zone-info');
  });
});
