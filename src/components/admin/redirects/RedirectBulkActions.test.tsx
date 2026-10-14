import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, it, expect, vi } from 'vitest';
import { RedirectBulkActions } from './RedirectBulkActions';
import { manualRedirect, type InventoryRedirect } from '@/lib/redirects/inventory';
const mocks = vi.hoisted(() => ({ bulk: vi.fn(), invoke: vi.fn() }));
vi.mock('@/hooks/useRedirectWorkspace', () => ({
  useRedirectWorkspace: () => ({
    data: {
      folders: [{ id: 'folder', name: 'Campaign' }],
      tags: [{ id: 'tag', name: 'Community' }],
    },
    bulk: { mutateAsync: mocks.bulk },
  }),
}));
vi.mock('@/integrations/supabase/client', () => ({
  supabase: { functions: { invoke: mocks.invoke } },
}));
const managed = manualRedirect({
  id: '00000000-0000-4000-8000-000000000001',
  type: 'SHORT',
  slug: 'campaign',
  target: '/events',
  is_enabled: true,
});
const automatic: InventoryRedirect = {
  id: 'static:fixture',
  source: '/old',
  target: '/new',
  origin: 'static',
  kind: 'Static',
  statusCode: 301,
  state: 'Enabled',
  updatedAt: null,
};
const clear = vi.fn();
function show(rows: InventoryRedirect[] = [managed, automatic]) {
  return render(
    <QueryClientProvider client={new QueryClient()}>
      <RedirectBulkActions rows={rows} onClear={clear} onExport={() => {}} />
    </QueryClientProvider>,
  );
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.bulk.mockResolvedValue(2);
});
describe('bulk redirect controls', () => {
  it('archives the exact selection and keeps source-owned rules undeletable', async () => {
    show();
    expect(screen.getByRole('button', { name: 'Delete selected links' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Apply to selected' }));
    await waitFor(() => expect(clear).toHaveBeenCalledOnce());
    expect(mocks.bulk).toHaveBeenCalledWith({
      keys: [managed.id, automatic.id],
      action: 'archive',
      value: null,
    });
  });
  it('adds a selected tag and preserves the selection after server failure', async () => {
    mocks.bulk.mockRejectedValue(new Error('Atomic change failed'));
    show();
    fireEvent.change(screen.getByLabelText('Bulk action'), { target: { value: 'add-tag' } });
    expect(screen.getByRole('button', { name: 'Apply to selected' })).toBeDisabled();
    fireEvent.change(screen.getByLabelText('Bulk tag'), { target: { value: 'tag' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply to selected' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Atomic change failed');
    expect(clear).not.toHaveBeenCalled();
  });
  it('requires a concrete typed confirmation before sending atomic deletes', async () => {
    mocks.invoke.mockResolvedValue({
      data: { data: [{ id: managed.manualId, deleted: true }] },
      error: null,
    });
    show([managed]);
    fireEvent.click(screen.getByRole('button', { name: 'Delete selected links' }));
    expect(screen.getByRole('button', { name: 'Permanently delete' })).toBeDisabled();
    expect(mocks.invoke).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText('Confirm link deletion'), {
      target: { value: 'DELETE' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Permanently delete' }));
    await waitFor(() => expect(clear).toHaveBeenCalledOnce());
    expect(mocks.invoke).toHaveBeenCalledWith('redirect-api/links/bulk', {
      body: { operations: [{ operation: 'delete', id: managed.manualId }] },
    });
  });
});
