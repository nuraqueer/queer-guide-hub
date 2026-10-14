import { fireEvent, render, screen } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { describe, expect, it, vi } from 'vitest';
import { RedirectConversionsPanel } from './RedirectConversionsPanel';
vi.mock('@/integrations/supabase/untyped', () => ({
  untypedFrom: () => {
    const q = {
      select: () => q,
      eq: () => q,
      order: () => q,
      range: () => q,
      gte: () => q,
      abortSignal: async () => ({
        data: null,
        count: null,
        error: { message: 'conversion read denied' },
      }),
    };
    return q;
  },
  untypedRpc: async () => ({ data: null, error: { message: 'journey read denied' } }),
}));
vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: { id: 'customer-owner' } }) }));
vi.mock('@/lib/redirects/memberApi', () => ({
  memberRedirectApi: async (path: string) => {
    if (path.includes('/customers/profile'))
      return {
        customerExternalId: 'customer-a',
        name: null,
        email: null,
        avatarUrl: null,
        version: null,
        canEdit: false,
      };
    throw new Error('journey read denied');
  },
}));
const client = () =>
  new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } });
describe('conversion report and journey', () => {
  it('shows real currency totals and a chronological cross-link customer journey', async () => {
    const cache = client();
    cache.setQueryData(
      ['redirect-conversion-report', 'customer-owner', 'link', '30'],
      [
        {
          id: 'lead',
          click_id: 'click',
          kind: 'lead',
          customer_key: 'customer-a',
          event_name: 'Sign up',
          occurred_at: '2026-10-13T10:00:00Z',
          amount: null,
          currency: null,
        },
        {
          id: 'sale',
          click_id: 'click',
          kind: 'sale',
          customer_key: 'customer-a',
          event_name: 'Purchase',
          occurred_at: '2026-10-13T11:00:00Z',
          amount: '49.9',
          currency: 'CHF',
        },
        {
          id: 'sale2',
          click_id: 'click2',
          kind: 'sale',
          customer_key: 'customer-b',
          event_name: 'Renewal',
          occurred_at: '2026-10-13T12:00:00Z',
          amount: '10.1',
          currency: 'EUR',
        },
      ],
    );
    cache.setQueryData(['redirect-customer-journey', 'customer-owner', 'customer-a'], {
      pages: [
        {
          data: [
            {
              id: 'click:click',
              kind: 'click',
              source: '/go/pride',
              event_name: 'Visit',
              occurred_at: '2026-10-13T09:00:00Z',
              amount: null,
              currency: null,
            },
            {
              id: 'conversion:sale',
              kind: 'sale',
              source: '/go/renewal',
              event_name: 'Purchase',
              occurred_at: '2026-10-13T11:00:00Z',
              amount: '49.9',
              currency: 'CHF',
            },
          ],
          nextCursor: null,
        },
      ],
      pageParams: [null],
    });
    render(
      <QueryClientProvider client={cache}>
        <RedirectConversionsPanel linkId="link" days="30" />
      </QueryClientProvider>,
    );
    expect(screen.getByText(/lead event/)).toHaveTextContent('1');
    expect(screen.getByText(/sale event/)).toHaveTextContent('2');
    expect(screen.getAllByText(/CHF/).length).toBeGreaterThan(0);
    expect(screen.getAllByText(/€|EUR/).length).toBeGreaterThan(0);
    fireEvent.click(screen.getAllByRole('button', { name: 'customer-a' })[0]);
    expect(await screen.findByRole('region', { name: 'Customer journey' })).toHaveTextContent(
      '/go/pride',
    );
    expect(screen.getByRole('region', { name: 'Customer journey' })).toHaveTextContent(
      '/go/renewal',
    );
  });
  it('reports failed conversion reads instead of displaying zero sales', async () => {
    render(
      <QueryClientProvider client={client()}>
        <RedirectConversionsPanel linkId="link" days="30" />
      </QueryClientProvider>,
    );
    expect(await screen.findByRole('alert')).toHaveTextContent('conversion read denied');
    expect(screen.queryByText('0 sale events')).toBeNull();
    expect(screen.getByRole('button', { name: 'Retry conversions' })).toBeVisible();
  });
});
