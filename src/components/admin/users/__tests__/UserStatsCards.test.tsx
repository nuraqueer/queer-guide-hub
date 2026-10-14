/**
 * @vitest-environment jsdom
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import type { ReactNode } from 'react';

const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }));

vi.mock('@/integrations/supabase/client', () => ({ supabase: { rpc: rpcMock } }));

import { UserStatsCards } from '../UserStatsCards';

function wrapper({ children }: { children: ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
}

beforeEach(() => {
  rpcMock.mockReset();
});

describe('UserStatsCards', () => {
  it('renders all four card labels', () => {
    rpcMock.mockResolvedValue({
      data: { total: 0, new_this_week: 0, online: 0, needs_moderation: 0 },
      error: null,
    });
    render(<UserStatsCards />, { wrapper });
    expect(screen.getByText('Total Users')).toBeInTheDocument();
    expect(screen.getByText('New This Week')).toBeInTheDocument();
    expect(screen.getByText('Active Now')).toBeInTheDocument();
    expect(screen.getByText('Moderation Issues')).toBeInTheDocument();
  });

  it('renders count values once query resolves, locale-formatted', async () => {
    rpcMock.mockResolvedValue({
      data: { total: 1234, new_this_week: 56, online: 7, needs_moderation: 2 },
      error: null,
    });
    render(<UserStatsCards />, { wrapper });
    await waitFor(() => expect(screen.getByText('1,234')).toBeInTheDocument());
    expect(screen.getByText('56')).toBeInTheDocument();
    expect(screen.getByText('7')).toBeInTheDocument();
    expect(screen.getByText('2')).toBeInTheDocument();
    expect(rpcMock).toHaveBeenCalledWith('admin_user_stats');
  });
});

it('shows an unavailable state and retries instead of reporting false zero counts', async () => {
  rpcMock
    .mockResolvedValueOnce({ data: null, error: { message: 'denied' } })
    .mockResolvedValue({
      data: { total: 42, new_this_week: 0, online: 0, needs_moderation: 0 },
      error: null,
    });
  render(<UserStatsCards />, { wrapper });
  await screen.findByRole('alert');
  expect(screen.queryByText('0')).not.toBeInTheDocument();
  expect(screen.getAllByText('—')).toHaveLength(4);
  fireEvent.click(screen.getByRole('button', { name: 'Retry statistics' }));
  await screen.findByText('42');
  expect(screen.queryByRole('alert')).not.toBeInTheDocument();
});
