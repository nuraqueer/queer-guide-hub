import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { MemberWorkspaceContent } from './RedirectMemberWorkspace';
const mocks = vi.hoisted(() => ({ invoke: vi.fn(), role: 'member', canEdit: true }));
vi.mock('@/integrations/supabase/client', () => ({
  supabase: { functions: { invoke: mocks.invoke } },
}));
vi.mock('@/hooks/useAuth', () => ({
  useAuth: () => ({ user: { id: 'account' }, loading: false }),
}));
const row = {
  id: '00000000-0000-4000-8000-000000000001',
  slug: 'pride',
  target: 'https://example.com/register',
  shortUrl: 'https://queer.guide/go/pride',
  folderId: null,
  tagIds: ['tag'],
  comment: 'Shared note',
  isEnabled: true,
  isArchived: false,
  clicks: 3,
  canEdit: true,
  statusCode: 302,
  queryMode: 'PRESERVE',
  utmDefaults: { utm_source: 'poster' },
  expiresAt: null,
  updatedAt: '2026-10-14T00:00:00Z',
};
function show(
  userId = 'account',
  client = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  }),
) {
  return {
    client,
    ...render(
      <QueryClientProvider client={client}>
        <MemberWorkspaceContent key={userId} userId={userId} />
      </QueryClientProvider>,
    ),
  };
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.role = 'member';
  mocks.canEdit = true;
  mocks.invoke.mockImplementation(async (path, options) => {
    if (path === 'redirect-api/session') return { data: { role: mocks.role }, error: null };
    if (path.includes('/folders?'))
      return {
        data: {
          data: [{ id: 'folder', name: 'Campaign', canEdit: true, canManage: true }],
          nextCursor: null,
        },
        error: null,
      };
    if (path.includes('/tags?'))
      return {
        data: { data: [{ id: 'tag', name: 'Pride', color: 'pink' }], nextCursor: null },
        error: null,
      };
    if (path.includes('/templates?'))
      return {
        data: {
          data: [
            {
              id: 'template',
              name: 'Email launch',
              parameters: { utm_source: 'email', utm_campaign: 'launch' },
            },
          ],
          nextCursor: null,
        },
        error: null,
      };
    if (path.includes('/links?'))
      return {
        data: { data: [{ ...row, canEdit: mocks.canEdit }], count: 1, nextCursor: null },
        error: null,
      };
    if (path.endsWith('/policy') && options.method === 'GET')
      return { data: { policy: { track_conversions: true }, hasPassword: false }, error: null };
    if (path.endsWith('/variants')) return { data: [], error: null };
    return { data: { id: row.id }, error: null };
  });
});
describe('member redirect workspace', () => {
  it('lets viewers read links and behavior while keeping mutation controls unavailable', async () => {
    mocks.role = 'viewer';
    mocks.canEdit = false;
    show();
    await screen.findByText('/go/pride');
    expect(screen.getByRole('button', { name: 'Create link' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Edit /go/pride' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Link behavior' }));
    expect(
      await screen.findByText(
        'You can view these settings. Edit access is required to change them.',
      ),
    ).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Save link behavior' })).toBeNull();
    expect(screen.getByRole('checkbox', { name: 'Attribute leads and sales' })).toBeDisabled();
    expect(mocks.invoke.mock.calls.every(([, options]) => options.method === 'GET')).toBe(true);
  });
  it('saves member policy changes through the scoped patch endpoint with explicit clearing', async () => {
    show();
    await screen.findByText('/go/pride');
    fireEvent.click(screen.getByRole('button', { name: 'Link behavior' }));
    const tracking = await screen.findByRole('checkbox', { name: 'Attribute leads and sales' });
    fireEvent.click(tracking);
    fireEvent.click(screen.getByRole('button', { name: 'Save link behavior' }));
    await waitFor(() =>
      expect(mocks.invoke).toHaveBeenCalledWith(
        'redirect-api/links/' + row.id + '/policy',
        expect.objectContaining({
          method: 'PATCH',
          body: expect.objectContaining({
            policy: expect.objectContaining({
              track_conversions: false,
              geo_targets: null,
              expires_at: null,
            }),
          }),
        }),
      ),
    );
    expect(mocks.invoke.mock.calls.some(([path]) => path === 'save-redirect-policy')).toBe(false);
  });
  it('prefills a new link, applies shared UTM templates and leaves its slug for server allocation', async () => {
    show();
    await screen.findByText('/go/pride');
    fireEvent.click(screen.getByRole('button', { name: 'Create from link' }));
    expect(screen.getByLabelText('Destination')).toHaveValue(row.target);
    expect(screen.getByLabelText('Short path')).toHaveValue('');
    expect(screen.getByLabelText('utm_source')).toHaveValue('poster');
    expect(screen.getByRole('checkbox', { name: 'Pride' })).toBeChecked();
    fireEvent.change(screen.getByLabelText('Prefill campaign template'), {
      target: { value: 'template' },
    });
    expect(screen.getByLabelText('utm_source')).toHaveValue('email');
    fireEvent.click(
      screen
        .getAllByRole('button', { name: 'Create link' })
        .find((b) => b.getAttribute('type') === 'submit')!,
    );
    await waitFor(() =>
      expect(mocks.invoke).toHaveBeenCalledWith(
        'redirect-api/links',
        expect.objectContaining({
          method: 'POST',
          body: expect.objectContaining({
            target: row.target,
            utmDefaults: { utm_source: 'email', utm_campaign: 'launch' },
            tagIds: ['tag'],
          }),
        }),
      ),
    );
    const call = mocks.invoke.mock.calls.find(
      ([path, options]) => path === 'redirect-api/links' && options.method === 'POST',
    );
    expect(call?.[1].body).not.toHaveProperty('slug');
  });
  it('does not issue a delete until confirmation and reports server permission denial', async () => {
    const initial = mocks.invoke.getMockImplementation()!;
    mocks.invoke.mockImplementation(async (path, options) =>
      path.endsWith('/links/bulk')
        ? { data: { error: 'Link is outside credential scope' }, error: null }
        : initial(path, options),
    );
    show();
    await screen.findByText('/go/pride');
    fireEvent.click(screen.getByRole('checkbox', { name: 'Select /go/pride' }));
    fireEvent.click(screen.getByRole('button', { name: 'Delete selected' }));
    expect(mocks.invoke.mock.calls.some(([path]) => path.endsWith('/links/bulk'))).toBe(false);
    fireEvent.click(screen.getByRole('button', { name: 'Confirm permanent deletion' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Link is outside credential scope');
    expect(screen.getByRole('checkbox', { name: 'Select /go/pride' })).toBeChecked();
  });
  it('does not show a previous account’s links while the next account is being verified', async () => {
    const view = show('first');
    await screen.findByText('/go/pride');
    mocks.invoke.mockImplementation(() => new Promise(() => {}));
    view.rerender(
      <QueryClientProvider client={view.client}>
        <MemberWorkspaceContent key="second" userId="second" />
      </QueryClientProvider>,
    );
    expect(screen.queryByText('/go/pride')).toBeNull();
    expect(screen.getByRole('status')).toHaveTextContent('Checking workspace access');
  });
});
