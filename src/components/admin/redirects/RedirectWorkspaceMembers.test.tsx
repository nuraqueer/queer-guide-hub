import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RedirectWorkspaceMembers } from './RedirectWorkspaceMembers';
const mocks = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock('@/integrations/supabase/client', () => ({
  supabase: { functions: { invoke: mocks.invoke } },
}));
const member = { id: 'member', label: 'Sam', kind: 'user', role: 'member', active: true };
function show() {
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <RedirectWorkspaceMembers />
    </QueryClientProvider>,
  );
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.invoke.mockImplementation(async (_path, options) => ({
    data: options.method === 'GET' ? { data: [member], count: 1 } : { id: 'member' },
    error: null,
  }));
});
describe('workspace membership editor', () => {
  it('requires a second explicit action before deleting membership and credentials', async () => {
    show();
    await screen.findByText('Sam');
    fireEvent.click(screen.getByRole('button', { name: 'Remove' }));
    expect(mocks.invoke.mock.calls.every(([, options]) => options.method !== 'DELETE')).toBe(true);
    expect(screen.getByText(/all bound API credentials/)).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Confirm removal' }));
    await waitFor(() =>
      expect(mocks.invoke).toHaveBeenCalledWith('redirect-api/members/member', {
        method: 'DELETE',
      }),
    );
  });
  it('can create a machine identity without an account identifier', async () => {
    show();
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Campaign worker' } });
    fireEvent.change(screen.getByLabelText('Identity'), { target: { value: 'machine' } });
    expect(screen.queryByLabelText('Account UUID')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Add member' }));
    await waitFor(() =>
      expect(mocks.invoke).toHaveBeenCalledWith('redirect-api/members', {
        method: 'POST',
        body: { label: 'Campaign worker', kind: 'machine', role: 'member' },
      }),
    );
  });
});
