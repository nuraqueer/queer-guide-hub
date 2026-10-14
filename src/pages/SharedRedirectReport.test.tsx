import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { afterEach, describe, it, expect, vi } from 'vitest';
import { SharedReportView } from './SharedRedirectReport';
const id = '00000000-0000-4000-8000-000000000001';
const data = {
  title: 'Public campaign',
  includeConversions: false,
  linkCount: 1,
  scopeMode: 'snapshot',
  expiresAt: null,
  report: {
    snapshot: '2026-10-14T00:00:00Z',
    interval: 'day',
    totals: { clicks: 3 },
    revenue: [],
    series: [{ at: '2026-10-14T00:00:00Z', clicks: 3 }],
    breakdowns: { country: [{ label: 'CH', count: 3 }] },
  },
};
function show() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={client}>
      <SharedReportView id={id} />
    </QueryClientProvider>,
  );
  return client;
}
afterEach(() => vi.unstubAllGlobals());
describe('public aggregate dashboard', () => {
  it('unlocks with a POST body and keeps the password out of URLs and query cache keys', async () => {
    const fetcher = vi
      .fn<typeof fetch>()
      .mockImplementation(async (_input, options) =>
        options?.method === 'POST'
          ? new Response(JSON.stringify(data))
          : new Response('{"error":"Password required","passwordRequired":true}', { status: 401 }),
      );
    vi.stubGlobal('fetch', fetcher);
    const client = show();
    await screen.findByLabelText('Dashboard password');
    fireEvent.change(screen.getByLabelText('Dashboard password'), {
      target: { value: 'private-password' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'View dashboard' }));
    expect(await screen.findByText('Public campaign')).toBeVisible();
    expect(fetcher).toHaveBeenCalledWith(
      '/api/redirects/public-report',
      expect.objectContaining({
        method: 'POST',
        credentials: 'omit',
        body: '{"password":"private-password"}',
      }),
    );
    expect(
      JSON.stringify(
        client
          .getQueryCache()
          .getAll()
          .map((q) => q.queryKey),
      ),
    ).not.toContain('private-password');
    expect(screen.queryByText('Revenue by currency')).toBeNull();
    expect(screen.queryByText('Event activity')).toBeNull();
  });
  it('removes the rendered data when a refresh reports revocation', async () => {
    const fetcher = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(JSON.stringify(data)))
      .mockResolvedValue(new Response('{"error":"Dashboard unavailable"}', { status: 404 }));
    vi.stubGlobal('fetch', fetcher);
    show();
    await screen.findByText('Public campaign');
    fireEvent.click(screen.getByRole('button', { name: 'Refresh dashboard' }));
    await waitFor(() => expect(screen.queryByText('Public campaign')).toBeNull());
    expect(await screen.findByRole('alert')).toHaveTextContent('Dashboard unavailable');
  });
});
