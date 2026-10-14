import { fireEvent, render, screen, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import AdminRedirects from '../AdminRedirects';
import { manualRedirect, type InventoryRedirect } from '@/lib/redirects/inventory';

const mocks = vi.hoisted(() => ({
  openEditor: vi.fn(),
  refetch: vi.fn(),
  inventory: {} as Record<string, unknown>,
  metadata: new Map<string, { is_archived?: boolean }>(),
}));
vi.mock('@/hooks/useRedirectWorkspace', () => ({
  useRedirectWorkspace: () => ({
    data: { folders: [], tags: [], templates: [], metadata: mocks.metadata },
    isError: false,
  }),
}));
vi.mock('@/components/admin/redirects/RedirectBulkActions', () => ({
  RedirectBulkActions: ({ rows, onClear }: { rows: InventoryRedirect[]; onClear: () => void }) => (
    <div aria-label="Selection fixture">
      {rows.length} selected<button onClick={onClear}>Clear selection</button>
    </div>
  ),
}));
vi.mock('@/hooks/useRedirectInventory', () => ({ useRedirectInventory: () => mocks.inventory }));
vi.mock('@/components/admin/shell/AdminShell', () => ({
  useAdminShell: () => ({ openEditor: mocks.openEditor }),
}));
vi.mock('@/components/admin/redirects/RedirectToolbarActions', () => ({
  RedirectToolbarActions: () => null,
}));

const row = (index: number): InventoryRedirect => ({
  id: `event:${index}`,
  source: `/events/old-${index}`,
  target: `/events/current-${index}`,
  origin: 'event_slug_redirects',
  kind: 'Automatic',
  statusCode: 301,
  state: 'Enabled',
  updatedAt: null,
});
function show() {
  return render(
    <MemoryRouter initialEntries={['/admin/content/redirects']}>
      <AdminRedirects />
    </MemoryRouter>,
  );
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.metadata = new Map();
  mocks.inventory = {
    data: { rows: Array.from({ length: 107 }, (_, index) => row(index)), errors: [] },
    isPending: false,
    isFetching: false,
    isError: false,
    refetch: mocks.refetch,
  };
});

describe('unified redirects index', () => {
  it('selects across pages up to 100, then clears selection when filters change', () => {
    show();
    fireEvent.click(screen.getByLabelText('Select visible redirects'));
    expect(screen.getByLabelText('Selection fixture')).toHaveTextContent('50 selected');
    fireEvent.click(screen.getByRole('button', { name: 'Next' }));
    fireEvent.click(screen.getByLabelText('Select visible redirects'));
    expect(screen.getByLabelText('Selection fixture')).toHaveTextContent('100 selected');
    fireEvent.click(screen.getByRole('button', { name: 'Next' }));
    for (const checkbox of within(screen.getByRole('table', { name: 'Redirects' }))
      .getAllByRole('checkbox')
      .slice(1))
      expect(checkbox).toBeDisabled();
    fireEvent.change(screen.getByRole('textbox', { name: 'Search redirects' }), {
      target: { value: 'current-106' },
    });
    expect(screen.queryByLabelText('Selection fixture')).toBeNull();
    expect(screen.getByLabelText('Select /events/old-106')).not.toBeDisabled();
  });
  it('hides archived rows from the active view and exposes an archived-only view', () => {
    mocks.metadata.set('event:0', { is_archived: true });
    show();
    expect(screen.queryByText('/events/old-0')).toBeNull();
    expect(screen.getByRole('status')).toHaveTextContent('of 106 redirects');
    fireEvent.change(screen.getByLabelText('Archive status'), { target: { value: 'archived' } });
    expect(screen.getByText('/events/old-0')).toBeVisible();
    expect(screen.getByRole('status')).toHaveTextContent('1–1 of 1 redirects');
  });
  it('paginates the complete list and resets pagination when searching destinations', () => {
    show();
    expect(
      within(screen.getByRole('table', { name: 'Redirects' })).getAllByRole('row'),
    ).toHaveLength(51);
    fireEvent.click(screen.getByRole('button', { name: 'Next' }));
    expect(screen.getByRole('status')).toHaveTextContent('51–100 of 107 redirects');
    fireEvent.change(screen.getByRole('textbox', { name: 'Search redirects' }), {
      target: { value: '/events/current-106' },
    });
    expect(screen.getByRole('status')).toHaveTextContent('1–1 of 1 redirects');
    expect(screen.getByText('/events/old-106')).toBeVisible();
    expect(screen.getByRole('button', { name: 'Next' })).toBeDisabled();
  });

  it('reports partial results and exposes a retry instead of saying the inventory is empty', () => {
    mocks.inventory.data = { rows: [row(1)], errors: ['venue_redirects: permission denied'] };
    show();
    expect(screen.getByRole('alert')).toHaveTextContent('incomplete');
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('≥ 1');
    fireEvent.click(screen.getByRole('button', { name: 'Retry failed sources' }));
    expect(mocks.refetch).toHaveBeenCalledOnce();
  });

  it('preserves the CMS manual editor and creation while automatic rules stay managed at source', () => {
    mocks.inventory.data = {
      rows: [
        row(1),
        manualRedirect({
          id: 'manual',
          type: 'SHORT',
          slug: 'promo',
          target: '/events',
          status_code: 301,
          is_enabled: true,
        }),
      ],
      errors: [],
    };
    show();
    fireEvent.pointerDown(
      within(screen.getByRole('row', { name: /\/go\/promo/ })).getByRole('button', {
        name: 'Tools',
      }),
    );
    fireEvent.click(screen.getByRole('menuitem', { name: 'Edit redirect' }));
    expect(mocks.openEditor).toHaveBeenCalledWith('redirects', 'manual');
    fireEvent.click(screen.getByRole('button', { name: 'New Redirect' }));
    expect(mocks.openEditor).toHaveBeenCalledWith('redirects', null);
  });
});
