import { MemoryRouter, Route, Routes, useLocation } from 'react-router';
import RedirectMemberWorkspace from '@/pages/RedirectMemberWorkspace';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RedirectInvitations, RedirectInvitationAcceptance } from './RedirectInvitations';
const mocks = vi.hoisted(() => ({ api: vi.fn(), user: { id: 'owner' } as { id: string } | null }));
vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: mocks.user }) }));
vi.mock('@/lib/redirects/memberApi', () => ({ memberRedirectApi: mocks.api }));
const secret = 'qg_invite_' + 'a'.repeat(64),
  url = 'https://queer.guide/links-workspace#invite=' + secret;
function view(accept = false) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  const tree = () => (
    <QueryClientProvider client={client}>
      {accept ? <RedirectInvitationAcceptance userId="recipient" /> : <RedirectInvitations />}
    </QueryClientProvider>
  );
  return { ...render(tree()), client, tree };
}
function create() {
  fireEvent.change(screen.getByLabelText('Recipient email'), {
    target: { value: 'recipient@example.org' },
  });
  fireEvent.change(screen.getByLabelText('Teammate name'), { target: { value: 'Teammate' } });
  fireEvent.click(screen.getByRole('button', { name: 'Create invitation' }));
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.user = { id: 'owner' };
  window.history.replaceState(null, '', '/');
  sessionStorage.clear();
  mocks.api.mockImplementation(async (path, method) => {
    if (path.startsWith('/invitations?')) return { data: [], count: 0 };
    if (path === '/invitations' && method === 'POST') return { invitationUrl: url };
    return { accepted: true };
  });
});
describe('recipient-bound workspace invitations', () => {
  it('shows a generated link once, hides it and never sends an email request', async () => {
    view();
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Create invitation' })).toBeEnabled(),
    );
    create();
    await screen.findByLabelText('Invitation link · shown once');
    expect(screen.getByLabelText('Invitation link · shown once')).toHaveValue(url);
    expect(mocks.api).toHaveBeenCalledWith('/invitations', 'POST', {
      email: 'recipient@example.org',
      label: 'Teammate',
      role: 'viewer',
    });
    fireEvent.click(screen.getByRole('button', { name: 'Hide invitation link' }));
    expect(screen.queryByLabelText('Invitation link · shown once')).toBeNull();
    expect(mocks.api.mock.calls.every(([path]) => path.startsWith('/invitations'))).toBe(true);
  });
  it('captures and removes a fragment before submitting its token in the body', async () => {
    window.history.replaceState(null, '', '/links-workspace#invite=' + secret);
    const v = view(true);
    expect(screen.getByLabelText('Invitation link')).toHaveValue(secret);
    expect(window.location.hash).toBe('');
    const invalidate = vi.spyOn(v.client, 'invalidateQueries');
    fireEvent.click(screen.getByRole('button', { name: 'Accept invitation' }));
    await screen.findByText('Invitation accepted. Workspace access refreshed.');
    expect(mocks.api).toHaveBeenCalledWith('/invitations/accept', 'POST', { token: secret });
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ['redirect-member', 'recipient'] });
    expect(screen.getByLabelText('Invitation link')).toHaveValue('');
  });
  it('keeps the invitation out of the sign-in redirect query', async () => {
    mocks.user = null;
    function AuthDestination() {
      const location = useLocation();
      return (
        <p data-testid="auth-location">{location.pathname + location.search + location.hash}</p>
      );
    }
    render(
      <MemoryRouter initialEntries={['/links-workspace#invite=' + secret]}>
        <Routes>
          <Route path="/links-workspace" element={<RedirectMemberWorkspace />} />
          <Route path="/auth" element={<AuthDestination />} />
        </Routes>
      </MemoryRouter>,
    );
    const destination = await screen.findByTestId('auth-location');
    expect(destination).toHaveTextContent('/auth?redirect=%2Flinks-workspace');
    expect(destination.textContent).not.toContain(secret);
    expect(JSON.parse(sessionStorage.getItem('redirect-pending-invitation')!)).toMatchObject({
      token: secret,
    });
  });
  it('consumes a fresh sign-in handoff once and discards expired handoffs', async () => {
    sessionStorage.setItem(
      'redirect-pending-invitation',
      JSON.stringify({ token: secret, at: Date.now() }),
    );
    const first = view(true);
    expect(screen.getByLabelText('Invitation link')).toHaveValue(secret);
    expect(sessionStorage.getItem('redirect-pending-invitation')).toBeNull();
    first.unmount();
    sessionStorage.setItem(
      'redirect-pending-invitation',
      JSON.stringify({ token: secret, at: Date.now() - 900001 }),
    );
    view(true);
    expect(screen.getByLabelText('Invitation link')).toHaveValue('');
    expect(sessionStorage.getItem('redirect-pending-invitation')).toBeNull();
  });
  it('keeps a denied acceptance visible without retrying automatically', async () => {
    mocks.api.mockRejectedValue(new Error('Invitation unavailable'));
    view(true);
    fireEvent.change(screen.getByLabelText('Invitation link'), { target: { value: url } });
    fireEvent.click(screen.getByRole('button', { name: 'Accept invitation' }));
    await screen.findByRole('alert');
    expect(mocks.api).toHaveBeenCalledTimes(1);
    expect(screen.queryByText('Invitation accepted. Workspace access refreshed.')).toBeNull();
  });
  it('ignores a late creation receipt after account switching', async () => {
    let finish!: (value: unknown) => void;
    mocks.api.mockImplementation(async (path) =>
      path === '/invitations'
        ? new Promise((resolve) => {
            finish = resolve;
          })
        : { data: [], count: 0 },
    );
    const v = view();
    create();
    await waitFor(() => expect(finish).toBeTypeOf('function'));
    mocks.user = { id: 'other' };
    v.rerender(v.tree());
    await act(async () => {
      finish({ invitationUrl: url });
    });
    expect(screen.queryByLabelText('Invitation link · shown once')).toBeNull();
  });
});
