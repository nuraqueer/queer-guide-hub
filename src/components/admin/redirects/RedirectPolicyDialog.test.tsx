import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { RedirectPolicyDialog } from './RedirectPolicyDialog';
import type { InventoryRedirect } from '@/lib/redirects/inventory';

vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: { id: 'fixture-owner' } }) }));
vi.mock('./RedirectPasswordBranding', () => ({ RedirectPasswordBranding: () => null }));
const mocks = vi.hoisted(() => ({ invoke: vi.fn(), closed: vi.fn() }));
vi.mock('@/integrations/supabase/client', () => ({
  supabase: { functions: { invoke: mocks.invoke } },
}));
vi.mock('@/integrations/supabase/untyped', () => ({
  untypedRpc: async () => ({ data: [], error: null }),
  untypedFrom: () => {
    const query = {
      select() {
        return query;
      },
      eq() {
        return query;
      },
      async maybeSingle() {
        return { data: { policy: {}, has_password: false }, error: null };
      },
      async single() {
        return { data: { end_at: null }, error: null };
      },
    };
    return query;
  },
}));
const row: InventoryRedirect = {
  id: 'redirects:fixture',
  manualId: 'fixture',
  source: '/go/fixture',
  target: 'https://example.com/default',
  origin: 'redirects',
  kind: 'Manual',
  statusCode: 302,
  state: 'Enabled',
  updatedAt: null,
};
function show(hasPassword = false) {
  const client = new QueryClient({
    defaultOptions: { queries: { staleTime: Infinity, retry: false } },
  });
  client.setQueryData(['redirect-link-policy', 'fixture', 'fixture-owner', 'owner'], {
    policy: {},
    hasPassword,
    stats: [],
  });
  return render(
    <QueryClientProvider client={client}>
      <RedirectPolicyDialog row={row} onClose={mocks.closed} />
    </QueryClientProvider>,
  );
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.invoke.mockResolvedValue({ data: {}, error: null });
});
describe('link behavior editor', () => {
  it('saves device/country targets and expiry through the authenticated policy endpoint', async () => {
    show();
    fireEvent.change(screen.getByLabelText('iOS'), {
      target: { value: 'https://apps.apple.com/app/fixture' },
    });
    fireEvent.change(screen.getByRole('textbox', { name: 'Country code' }), {
      target: { value: 'ch' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Add country' }));
    fireEvent.change(screen.getByRole('textbox', { name: 'Destination for CH' }), {
      target: { value: 'https://example.com/ch' },
    });
    fireEvent.change(screen.getByLabelText('Expired destination'), {
      target: { value: '/expired' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Save link behavior' }));
    await waitFor(() => expect(mocks.invoke).toHaveBeenCalledOnce());
    expect(mocks.invoke).toHaveBeenCalledWith(
      'save-redirect-policy',
      expect.objectContaining({
        body: expect.objectContaining({
          policy: expect.objectContaining({
            device_targets: { ios: 'https://apps.apple.com/app/fixture' },
            geo_targets: { CH: 'https://example.com/ch' },
            expired_target: '/expired',
          }),
        }),
      }),
    );
    await waitFor(() => expect(mocks.closed).toHaveBeenCalledOnce());
  });
  it('requires a new password but can keep an existing protected password without exposing it', async () => {
    show();
    fireEvent.click(screen.getByRole('checkbox', { name: 'Require a password' }));
    fireEvent.click(screen.getByRole('button', { name: 'Save link behavior' }));
    expect(screen.getByRole('alert')).toHaveTextContent('Enter or generate');
    expect(mocks.invoke).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText('Link password'), {
      target: { value: 'fixture-only-password' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Save link behavior' }));
    await waitFor(() =>
      expect(mocks.invoke).toHaveBeenCalledWith(
        'save-redirect-policy',
        expect.objectContaining({
          body: expect.objectContaining({ password: 'fixture-only-password' }),
        }),
      ),
    );
  });
  it('validates experiment splits before saving', () => {
    show();
    fireEvent.click(screen.getByRole('button', { name: 'Add A/B experiment' }));
    const urls = screen.getAllByRole('textbox', { name: 'Variant destination' });
    fireEvent.change(urls[1], { target: { value: 'https://example.com/b' } });
    fireEvent.change(screen.getAllByRole('spinbutton', { name: 'Traffic percentage' })[0], {
      target: { value: 70 },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Save link behavior' }));
    expect(screen.getByRole('alert')).toHaveTextContent('100%');
    expect(mocks.invoke).not.toHaveBeenCalled();
  });
});
