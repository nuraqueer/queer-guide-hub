vi.mock('./RedirectSavedReports', () => ({ RedirectSavedReports: () => null }));
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RedirectAnalyticsDialog } from './RedirectAnalyticsDialog';
const mocks = vi.hoisted(() => ({
  filters: null as unknown,
  live: false,
  report: {
    isPending: false,
    isError: false,
    isFetching: false,
    data: {
      snapshot: '2026-10-14T00:00:00Z',
      totals: { clicks: 3, leads: 1, sales: 1, customers: 1 },
      revenue: [{ currency: 'CHF', amount: '49.900000' }],
      series: [{ at: '2026-10-13T00:00:00Z', clicks: 3, leads: 1, sales: 1 }],
      breakdowns: {
        device: [{ label: 'Mobile', count: 5 }],
        city: [{ label: 'Zurich', count: 5 }],
      },
      interval: 'day',
    },
    refetch: vi.fn(),
  },
  events: {
    isPending: false,
    isError: false,
    isSuccess: true,
    data: { pages: [{ data: [], nextCursor: null }] },
    hasNextPage: false,
    refetch: vi.fn(),
  },
}));
vi.mock('@/hooks/useRedirectWorkspace', () => ({
  useRedirectWorkspace: () => ({
    data: { folders: [{ id: 'folder', name: 'Campaigns' }], tags: [{ id: 'tag', name: 'Pride' }] },
    isError: false,
  }),
}));
vi.mock('@/hooks/useRedirectAnalytics', () => ({
  useRedirectAnalytics: (filters: unknown, live: boolean) => {
    mocks.filters = filters;
    mocks.live = live;
    return { report: mocks.report, events: mocks.events };
  },
  readAnalyticsPage: vi.fn(),
}));
beforeEach(() => {
  vi.clearAllMocks();
});
describe('detailed analytics controls', () => {
  it('applies inclusive custom dates and workspace/dimension filters explicitly', async () => {
    render(<RedirectAnalyticsDialog links={[]} onClose={vi.fn()} />);
    fireEvent.click(screen.getByRole('button', { name: 'Filter report' }));
    fireEvent.change(screen.getByLabelText('Start date (UTC)'), {
      target: { value: '2026-10-01' },
    });
    fireEvent.change(screen.getByLabelText('End date (UTC)'), { target: { value: '2026-10-13' } });
    fireEvent.change(screen.getByLabelText('Folder'), { target: { value: 'folder' } });
    fireEvent.change(screen.getByLabelText('Tag'), { target: { value: 'tag' } });
    fireEvent.change(screen.getByLabelText('Country code'), { target: { value: 'ch' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply filters' }));
    await waitFor(() =>
      expect(mocks.filters).toMatchObject({
        folderId: 'folder',
        tagId: 'tag',
        country: 'CH',
        start: '2026-10-01T00:00:00.000Z',
        end: '2026-10-14T00:00:00.000Z',
      }),
    );
    expect(screen.getAllByText(/49.90/).length).toBeGreaterThan(0);
    expect(screen.getByRole('img', { name: 'Clicks, leads and sales over time' })).toBeVisible();
  });
  it('starts and stops polling by explicit choice and exposes complete-event export', () => {
    render(<RedirectAnalyticsDialog links={[]} onClose={vi.fn()} />);
    fireEvent.click(screen.getByRole('checkbox', { name: 'Live updates (every 5 seconds)' }));
    expect(mocks.live).toBe(true);
    fireEvent.click(screen.getByRole('checkbox', { name: 'Live updates (every 5 seconds)' }));
    expect(mocks.live).toBe(false);
    expect(screen.getByRole('button', { name: 'Export all matching events' })).toBeEnabled();
  });
});
