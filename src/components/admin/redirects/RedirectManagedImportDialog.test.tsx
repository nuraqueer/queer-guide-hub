import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { beforeEach, describe, it, expect, vi } from 'vitest';
import { RedirectManagedImportDialog } from './RedirectManagedImportDialog';
const mocks = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock('@/integrations/supabase/client', () => ({
  supabase: { functions: { invoke: mocks.invoke } },
}));
const close = vi.fn(),
  path = vi.fn();
function show() {
  return render(
    <QueryClientProvider client={new QueryClient()}>
      <RedirectManagedImportDialog onClose={close} onPathImport={path} />
    </QueryClientProvider>,
  );
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.invoke.mockResolvedValue({
    data: { data: [{ operation: 'create', created: true, link: { id: 'fixture' } }] },
    error: null,
  });
});
describe('managed import review', () => {
  it('requires review before sending one atomic batch and prevents duplicate submission', async () => {
    show();
    fireEvent.change(screen.getByLabelText('Managed links CSV'), {
      target: { value: 'slug,target\npride,/events' },
    });
    expect(screen.queryByRole('button', { name: 'Apply 1 row' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Review import' }));
    expect(mocks.invoke).not.toHaveBeenCalled();
    expect(screen.getByText('pride')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Apply 1 row' }));
    expect(await screen.findByText('Applied 1 row successfully.')).toBeVisible();
    expect(mocks.invoke).toHaveBeenCalledWith('redirect-api/links/bulk', {
      body: { operations: [{ operation: 'create', data: { slug: 'pride', target: '/events' } }] },
    });
    expect(screen.getByRole('button', { name: 'Apply 1 row' })).toBeDisabled();
  });
  it('invalidates reviewed data when mode or CSV changes and reports invalid rows without requests', () => {
    show();
    fireEvent.change(screen.getByLabelText('Managed links CSV'), {
      target: { value: 'slug,target\npride,/events' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Review import' }));
    fireEvent.change(screen.getByLabelText('Managed import mode'), { target: { value: 'upsert' } });
    expect(screen.queryByRole('button', { name: 'Apply 1 row' })).toBeNull();
    fireEvent.change(screen.getByLabelText('Managed links CSV'), {
      target: { value: 'slug,target\npride,http://127.0.0.1' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Review import' }));
    expect(screen.getByRole('alert')).toHaveTextContent('Row 2');
    expect(mocks.invoke).not.toHaveBeenCalled();
  });
  it('keeps the review after an API error and does not report success', async () => {
    mocks.invoke.mockResolvedValue({ data: { error: 'Slug already exists' }, error: null });
    show();
    fireEvent.change(screen.getByLabelText('Managed links CSV'), {
      target: { value: 'slug,target\npride,/events' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Review import' }));
    fireEvent.click(screen.getByRole('button', { name: 'Apply 1 row' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Slug already exists');
    expect(screen.queryByText(/successfully/)).toBeNull();
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Apply 1 row' })).not.toBeDisabled(),
    );
  });
  it('exposes the preserved path-rule workflow', () => {
    show();
    fireEvent.click(screen.getByRole('button', { name: 'Import path rules instead' }));
    expect(path).toHaveBeenCalledOnce();
  });
});
