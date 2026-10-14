import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RedirectWebhooks } from './RedirectWebhooks';
const fixture = vi.hoisted(() => ({ account: 'owner', request: vi.fn() }));
vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: { id: fixture.account } }) }));
vi.mock('@/lib/redirects/memberApi', () => ({
  memberRedirectApi: (...args: unknown[]) => fixture.request(...args),
}));
const row = {
  id: 'd0000000-0000-4000-8000-000000000001',
  version: 'e0000000-0000-4000-8000-000000000001',
  name: 'Receiver',
  url: 'https://receiver.example.org/events',
  eventTypes: ['link.clicked'],
  linkIds: null,
  includeCustomerId: false,
  enabled: true,
  deletedAt: null,
};
function show() {
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <RedirectWebhooks />
    </QueryClientProvider>,
  );
}
beforeEach(() => {
  fixture.account = 'owner';
  fixture.request.mockReset();
  fixture.request.mockImplementation(async (path: string) =>
    path.startsWith('/webhooks?')
      ? { data: [row], nextCursor: null }
      : { data: [], nextCursor: null },
  );
});
describe('outgoing webhook controls', () => {
  it('prefills settings and preserves the version for changes', async () => {
    const view = show();
    fireEvent.click(await screen.findByRole('button', { name: 'Manage Receiver' }));
    expect(screen.getByLabelText('Name')).toHaveValue('Receiver');
    expect(screen.getByLabelText('HTTPS endpoint')).toHaveValue(row.url);
    fixture.request.mockImplementation(async (path: string, method: string, body: unknown) =>
      method === 'PATCH'
        ? { ...row, ...(body as object) }
        : path.startsWith('/webhooks?')
          ? { data: [row], nextCursor: null }
          : { data: [], nextCursor: null },
    );
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Updated Receiver' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save webhook' }));
    await screen.findByText('Webhook saved.');
    expect(fixture.request).toHaveBeenCalledWith(
      '/webhooks/' + row.id,
      'PATCH',
      expect.objectContaining({
        name: 'Updated Receiver',
        version: row.version,
        linkIds: null,
        includeCustomerId: false,
      }),
      expect.any(AbortSignal),
    );
    view.unmount();
  });
  it('shows rotation secret once and destroys it after an account switch', async () => {
    const view = show();
    fireEvent.click(await screen.findByRole('button', { name: 'Manage Receiver' }));
    fixture.request.mockImplementation(async (path: string) =>
      path.endsWith('/rotate')
        ? { ...row, secret: 'whsec_private_fixture' }
        : path.startsWith('/webhooks?')
          ? { data: [row], nextCursor: null }
          : { data: [], nextCursor: null },
    );
    fireEvent.click(screen.getByRole('button', { name: 'Rotate secret' }));
    fireEvent.click(screen.getByRole('button', { name: 'Confirm rotate' }));
    await screen.findByText('whsec_private_fixture');
    fixture.account = 'other-owner';
    view.rerender(
      <QueryClientProvider client={new QueryClient()}>
        <RedirectWebhooks />
      </QueryClientProvider>,
    );
    await waitFor(() =>
      expect(screen.queryByText('whsec_private_fixture')).not.toBeInTheDocument(),
    );
    view.unmount();
  });
  it('does not request an unselected receipt when refreshing history', async () => {
    const view = show();
    fireEvent.click(await screen.findByRole('button', { name: 'Manage Receiver' }));
    fireEvent.click(screen.getByRole('button', { name: 'Refresh history' }));
    await screen.findByText('No deliveries yet.');
    expect(fixture.request.mock.calls.some(([path]) => String(path).endsWith('/null'))).toBe(false);
    view.unmount();
  });
  it('keeps stale edits reviewable and requires reload after a version conflict', async () => {
    const view = show();
    fireEvent.click(await screen.findByRole('button', { name: 'Manage Receiver' }));
    fixture.request.mockImplementation(async (path: string, method: string) => {
      if (method === 'PATCH') throw new Error('Webhook changed; reload before saving');
      if (path === '/webhooks/' + row.id)
        return {
          ...row,
          name: 'Other owner edit',
          version: 'f0000000-0000-4000-8000-000000000001',
        };
      return { data: path.startsWith('/webhooks?') ? [row] : [], nextCursor: null };
    });
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'My stale edit' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save webhook' }));
    await screen.findByText(/Webhook changed; reload before saving/);
    expect(screen.getByLabelText('Name')).toHaveValue('My stale edit');
    fireEvent.click(screen.getByRole('button', { name: 'Reload settings' }));
    await waitFor(() => expect(screen.getByLabelText('Name')).toHaveValue('Other owner edit'));
    view.unmount();
  });
});
