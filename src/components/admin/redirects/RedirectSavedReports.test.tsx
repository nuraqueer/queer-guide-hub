import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, it, expect, vi } from 'vitest';
import { RedirectSavedReports } from './RedirectSavedReports';
const mocks = vi.hoisted(() => ({ invoke: vi.fn(), load: vi.fn() }));
vi.mock('@/integrations/supabase/client', () => ({
  supabase: { functions: { invoke: mocks.invoke } },
}));
const report = {
  id: 'report',
  name: 'Saved campaign',
  version: '00000000-0000-4000-8000-000000000001',
  filters: { country: 'CH', start: '2026-10-01T00:00:00Z', end: '2026-10-14T00:00:00Z' },
};
function show() {
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <RedirectSavedReports principalId="account" filters={{ country: 'US' }} onLoad={mocks.load} />
    </QueryClientProvider>,
  );
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.invoke.mockImplementation(async (path, options) => ({
    data:
      options.method === 'GET'
        ? path.endsWith('/shares')
          ? { data: [] }
          : { data: [report], count: 1, nextCursor: null }
        : path.endsWith('/shares')
          ? { id: 'share' }
          : report,
    error: null,
  }));
});
describe('saved-report review controls', () => {
  it('loads the saved filters and saves current applied filters with a version guard', async () => {
    show();
    fireEvent.click(screen.getByText('Saved reports and sharing'));
    fireEvent.click(await screen.findByRole('button', { name: 'Load report' }));
    expect(mocks.load).toHaveBeenCalledWith(report.filters);
    fireEvent.change(screen.getByLabelText('Report name'), { target: { value: 'Updated' } });
    fireEvent.click(screen.getByRole('button', { name: 'Update selected report' }));
    await waitFor(() =>
      expect(mocks.invoke).toHaveBeenCalledWith(
        'redirect-api/reports/report',
        expect.objectContaining({
          method: 'PATCH',
          body: { name: 'Updated', filters: { country: 'US' }, version: report.version },
        }),
      ),
    );
  });
  it('does not publish until the public scope/options are reviewed and confirmed', async () => {
    show();
    fireEvent.click(screen.getByText('Saved reports and sharing'));
    fireEvent.click(await screen.findByRole('button', { name: 'Load report' }));
    fireEvent.click(screen.getByRole('button', { name: 'Share selected report' }));
    fireEvent.click(screen.getByRole('button', { name: 'Review public sharing' }));
    expect(
      mocks.invoke.mock.calls.some(
        ([path, options]) => path.endsWith('/shares') && options.method === 'POST',
      ),
    ).toBe(false);
    fireEvent.click(screen.getByRole('button', { name: 'Confirm public sharing' }));
    await waitFor(() =>
      expect(mocks.invoke).toHaveBeenCalledWith(
        'redirect-api/reports/report/shares',
        expect.objectContaining({
          method: 'POST',
          body: expect.objectContaining({
            includeConversions: false,
            scopeMode: 'snapshot',
            reportVersion: report.version,
          }),
        }),
      ),
    );
  });
  it('requires confirmation before deleting a report and its public dashboards', async () => {
    show();
    fireEvent.click(screen.getByText('Saved reports and sharing'));
    fireEvent.click(await screen.findByRole('button', { name: 'Load report' }));
    fireEvent.click(screen.getByRole('button', { name: 'Delete selected report' }));
    expect(mocks.invoke.mock.calls.some(([, options]) => options.method === 'DELETE')).toBe(false);
    fireEvent.click(screen.getByRole('button', { name: 'Confirm report deletion' }));
    await waitFor(() =>
      expect(mocks.invoke).toHaveBeenCalledWith(
        'redirect-api/reports/report',
        expect.objectContaining({ method: 'DELETE' }),
      ),
    );
  });
});
