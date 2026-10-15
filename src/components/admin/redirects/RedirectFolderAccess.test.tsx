import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RedirectFolderAccess } from './RedirectFolderAccess';
const mocks = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock('@/integrations/supabase/client', () => ({
  supabase: { functions: { invoke: mocks.invoke } },
}));
const access = {
  folderId: 'folder',
  defaultPermission: 'view',
  members: [
    { id: 'member', label: 'Sam', kind: 'user', role: 'member', active: true, permission: 'edit' },
  ],
};
function show() {
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <RedirectFolderAccess folderId="folder" onClose={() => {}} />
    </QueryClientProvider>,
  );
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.invoke.mockResolvedValue({ data: access, error: null });
});
describe('folder access editor', () => {
  it('sends only changed settings and explicitly clears an override to inherit', async () => {
    show();
    await screen.findByLabelText('Sam');
    expect(screen.getByRole('button', { name: 'Save access' })).toBeDisabled();
    fireEvent.change(screen.getByLabelText('Sam'), { target: { value: '' } });
    fireEvent.change(screen.getByLabelText('Default for workspace members'), {
      target: { value: 'none' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Save access' }));
    await waitFor(() =>
      expect(mocks.invoke).toHaveBeenCalledWith('redirect-api/folders/folder/access', {
        method: 'PATCH',
        body: { defaultPermission: 'none', overrides: [{ memberId: 'member', permission: null }] },
      }),
    );
  });
  it('keeps edits after a denied save so the user can correct or retry', async () => {
    mocks.invoke.mockImplementation(async (_path, options) =>
      options.method === 'PATCH'
        ? { data: { error: 'Folder owner access is required' }, error: null }
        : { data: access, error: null },
    );
    show();
    await screen.findByLabelText('Sam');
    fireEvent.change(screen.getByLabelText('Sam'), { target: { value: 'none' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save access' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Folder owner access is required');
    expect(screen.getByLabelText('Sam')).toHaveValue('none');
  });
});
