import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { RedirectCustomerDetails } from '../RedirectCustomerDetails';
import { memberRedirectApi } from '@/lib/redirects/memberApi';
const state = vi.hoisted(() => ({ user: 'owner-a' }));
vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: { id: state.user } }) }));
vi.mock('@/lib/redirects/memberApi', () => ({ memberRedirectApi: vi.fn() }));
const api = vi.mocked(memberRedirectApi),
  id = 'external:customer & ü';
const version = '00000000-0000-4000-8000-000000000001',
  changed = '00000000-0000-4000-8000-000000000002';
const profile = (name = 'Avery') => ({
  customerExternalId: id,
  name,
  email: 'avery@example.com',
  avatarUrl: null,
  version,
  updatedAt: '2026-10-14T12:00:00Z',
  canEdit: true,
});
const events = {
  data: [
    {
      id: 'click:' + version,
      kind: 'click',
      occurred_at: '2026-10-14T10:00:00Z',
      source: '/go/newsletter',
      event_name: 'Visit',
      amount: null,
      currency: null,
      click_id: version,
    },
  ],
  nextCursor: null,
};
function fixture() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  const element = () => (
    <QueryClientProvider client={client}>
      <RedirectCustomerDetails customer={id} onClose={vi.fn()} />
    </QueryClientProvider>
  );
  return { client, element, ...render(element()) };
}
beforeEach(() => {
  vi.clearAllMocks();
  state.user = 'owner-a';
  api.mockImplementation(async (path) =>
    path.startsWith('/customers/journey') ? events : profile(),
  );
});
afterEach(cleanup);
describe('private customer identity UI', () => {
  it('prefills the selected identity and preserves its reviewed version through background refresh', async () => {
    const view = fixture();
    await screen.findByText('avery@example.com');
    fireEvent.click(screen.getByRole('button', { name: 'Edit customer identity' }));
    expect(screen.getByLabelText('Customer name')).toHaveValue('Avery');
    expect(screen.getByLabelText('Customer email')).toHaveValue('avery@example.com');
    api.mockImplementation(async (path, method) => {
      if (path.startsWith('/customers/journey')) return events;
      if (method === 'PATCH') throw new Error('Customer profile changed; reload before saving');
      return { ...profile(), version: changed, name: 'Elsewhere' };
    });
    await act(async () => {
      await view.client.invalidateQueries({
        queryKey: ['redirect-customer-profile', 'owner-a', id],
      });
    });
    fireEvent.change(screen.getByLabelText('Customer name'), {
      target: { value: 'Reviewed draft' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Save customer identity' }));
    await screen.findByText(/Customer profile changed; reload before saving/);
    const request = api.mock.calls.find((call) => call[1] === 'PATCH')!;
    expect(request[2]).toMatchObject({ customerExternalId: id, version, name: 'Reviewed draft' });
    expect(screen.getByRole('button', { name: 'Save customer identity' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Reload customer identity' }));
    await screen.findByText('Elsewhere');
  });
  it('confirms clearing only identity fields while keeping the chronological journey', async () => {
    fixture();
    await screen.findByText('avery@example.com');
    fireEvent.click(screen.getByRole('button', { name: 'Clear customer identity' }));
    expect(api.mock.calls.some((call) => call[1] === 'DELETE')).toBe(false);
    api.mockImplementation(async (path, method) =>
      method === 'DELETE'
        ? { ...profile(), name: null, email: null, avatarUrl: null, version: changed }
        : path.startsWith('/customers/journey')
          ? events
          : profile(),
    );
    fireEvent.click(screen.getByRole('button', { name: 'Confirm clear identity' }));
    await screen.findByText('Customer identity saved.');
    expect(screen.queryByText('avery@example.com')).toBeNull();
    expect(screen.getByText('/go/newsletter')).toBeVisible();
    expect(api.mock.calls.find((call) => call[1] === 'DELETE')?.[2]).toEqual({
      customerExternalId: id,
      version,
    });
  });
  it('does not apply late saves to another account and clears old private display', async () => {
    const view = fixture();
    await screen.findByText('avery@example.com');
    fireEvent.click(screen.getByRole('button', { name: 'Edit customer identity' }));
    let resolve!: (value: unknown) => void;
    api.mockImplementation(async (path, method) =>
      method === 'PATCH'
        ? new Promise((done) => {
            resolve = done;
          })
        : path.startsWith('/customers/journey')
          ? events
          : { ...profile('Second account'), email: 'second@example.com' },
    );
    fireEvent.click(screen.getByRole('button', { name: 'Save customer identity' }));
    await waitFor(() => expect(resolve).toBeDefined());
    state.user = 'owner-b';
    view.rerender(view.element());
    await screen.findByText('second@example.com');
    await act(async () =>
      resolve({ ...profile('Late old response'), email: 'old-private@example.com' }),
    );
    expect(screen.queryByText('old-private@example.com')).toBeNull();
    expect(screen.getByText('Second account')).toBeVisible();
  });
  it('hides cached identity after access denial and offers a fresh retry', async () => {
    const view = fixture();
    await screen.findByText('avery@example.com');
    api.mockImplementation(async (path) => {
      if (path.startsWith('/customers/journey')) return events;
      throw new Error('Customer access denied');
    });
    await act(async () => {
      await view.client.invalidateQueries({
        queryKey: ['redirect-customer-profile', 'owner-a', id],
      });
    });
    await screen.findByText('Customer access denied');
    expect(screen.queryByText('avery@example.com')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Edit customer identity' })).toBeNull();
  });
  it('renders read-only identity and anonymous no-referrer avatars with failure fallback', async () => {
    api.mockImplementation(async (path) =>
      path.startsWith('/customers/journey')
        ? events
        : { ...profile(), canEdit: false, avatarUrl: 'https://example.com/avatar.png' },
    );
    fixture();
    const image = await screen.findByAltText('Customer avatar');
    expect(image).toHaveAttribute('crossorigin', 'anonymous');
    expect(image).toHaveAttribute('referrerpolicy', 'no-referrer');
    expect(screen.queryByRole('button', { name: 'Edit customer identity' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Clear customer identity' })).toBeNull();
    fireEvent.error(image);
    expect(screen.queryByAltText('Customer avatar')).toBeNull();
  });
});
