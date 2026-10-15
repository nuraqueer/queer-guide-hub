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
  dateRange: {
    start: '2026-10-01T00:00:00.000Z',
    end: '2026-10-15T00:00:00.000Z',
    earliest: '2026-10-01T00:00:00.000Z',
    latest: '2026-10-15T00:00:00.000Z',
  },
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
  it('narrows UTC dates in POST bodies, resets to published dates, and keeps date errors recoverable', async () => {
    const fetcher = vi.fn<typeof fetch>().mockImplementation(async (_input, options) => {
      const body = options?.body ? JSON.parse(String(options.body)) : {};
      if (body.dates?.start === '2026-10-03T00:00:00.000Z')
        return new Response('{"error":"Choose a shorter date range"}', { status: 400 });
      return new Response(
        JSON.stringify({ ...data, dateRange: { ...data.dateRange, ...body.dates } }),
      );
    });
    vi.stubGlobal('fetch', fetcher);
    show();
    await screen.findByRole('region', { name: 'Reporting dates' });
    fireEvent.click(screen.getByRole('button', { name: 'Last 7 days' }));
    await waitFor(() =>
      expect(fetcher).toHaveBeenLastCalledWith(
        '/api/redirects/public-report',
        expect.objectContaining({
          method: 'POST',
          body: '{"dates":{"start":"2026-10-07T00:00:00.000Z","end":"2026-10-14T00:00:00.000Z"}}',
        }),
      ),
    );
    await waitFor(() => expect(screen.getByRole('button', { name: 'Apply dates' })).toBeEnabled());
    fireEvent.change(screen.getByLabelText('Start (UTC)'), {
      target: { value: '2026-10-03T00:00:00' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Apply dates' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Choose a shorter date range');
    expect(screen.queryByText('Public campaign')).toBeNull();
    expect(screen.getByRole('button', { name: 'Published dates' })).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Published dates' }));
    await screen.findByText('Public campaign');
    expect(fetcher).toHaveBeenLastCalledWith(
      '/api/redirects/public-report',
      expect.objectContaining({ method: 'GET' }),
    );
  });
  it('sets index metadata only after the sanitized public response opts in and removes it on revocation', async () => {
    vi.stubGlobal(
      'fetch',
      vi
        .fn<typeof fetch>()
        .mockResolvedValueOnce(new Response(JSON.stringify({ ...data, allowIndexing: true })))
        .mockImplementation(
          async () => new Response('{"error":"Dashboard unavailable"}', { status: 404 }),
        ),
    );
    show();
    await screen.findByText('Public campaign');
    expect(document.head.querySelector('meta[name="robots"]')?.getAttribute('content')).toBe(
      'index,follow',
    );
    fireEvent.click(screen.getByRole('button', { name: 'Refresh dashboard' }));
    await screen.findByRole('alert');
    expect(document.head.querySelector('meta[name="robots"]')?.getAttribute('content')).toBe(
      'noindex,nofollow',
    );
  });
  it('rejects a reversed custom range without a request', async () => {
    const fetcher = vi
      .fn<typeof fetch>()
      .mockImplementation(async () => new Response(JSON.stringify(data)));
    vi.stubGlobal('fetch', fetcher);
    show();
    await screen.findByRole('region', { name: 'Reporting dates' });
    fireEvent.change(screen.getByLabelText('Start (UTC)'), {
      target: { value: '2026-10-14T00:00:00' },
    });
    fireEvent.change(screen.getByLabelText('End (UTC, exclusive)'), {
      target: { value: '2026-10-13T00:00:00' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Apply dates' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Start must be before end');
    expect(fetcher).toHaveBeenCalledTimes(1);
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
    expect(screen.queryByRole('region', { name: 'Reporting dates' })).toBeNull();
  });
});
