import { act, renderHook } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { useCreateCheckoutSession } from '../useDonations';
import { captureRedirectAttribution } from '@/lib/redirects/attribution';
const mocks = vi.hoisted(() => ({ allowed: true, invoke: vi.fn() }));
vi.mock('@/integrations/supabase/client', () => ({
  supabase: { functions: { invoke: mocks.invoke } },
}));
vi.mock('@/lib/analyticsConsent', () => ({ analyticsAllowed: () => mocks.allowed }));
const click = '00000000-0000-4000-8000-000000000001';
beforeEach(() => {
  localStorage.clear();
  mocks.allowed = true;
  vi.clearAllMocks();
  mocks.invoke.mockResolvedValue({
    data: { url: 'https://checkout.stripe.com/fixture' },
    error: null,
  });
  captureRedirectAttribution(new URL('https://queer.guide/donate?qg_click_id=' + click), true);
});
function show() {
  const client = new QueryClient();
  return renderHook(() => useCreateCheckoutSession(), {
    wrapper: ({ children }) => (
      <QueryClientProvider client={client}>{children}</QueryClientProvider>
    ),
  });
}
describe('native checkout consent', () => {
  it('carries only the consented attribution into the existing checkout request', async () => {
    const { result } = show();
    await act(async () => {
      await result.current.mutateAsync({
        amount: 4990,
        currency: 'chf',
        email: 'fixture@example.com',
        donation_type: 'one_time',
      });
    });
    expect(mocks.invoke.mock.calls[0]).toMatchObject([
      'create-checkout-session',
      { body: { qg_click_id: click, amount: 4990, currency: 'chf' } },
    ]);
  });
  it('drops attribution on consent withdrawal and still allows checkout', async () => {
    mocks.allowed = false;
    const { result } = show();
    await act(async () => {
      expect(
        await result.current.mutateAsync({
          amount: 4990,
          currency: 'chf',
          email: 'fixture@example.com',
          donation_type: 'one_time',
        }),
      ).toBe('https://checkout.stripe.com/fixture');
    });
    expect(mocks.invoke.mock.calls[0][1].body.qg_click_id).toBeUndefined();
  });
});
