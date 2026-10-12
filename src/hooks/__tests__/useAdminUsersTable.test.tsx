import { describe, expect, it, vi } from 'vitest';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { renderHook, waitFor } from '@testing-library/react';
import type { ReactNode } from 'react';

const { rpc, from } = vi.hoisted(() => ({ rpc: vi.fn(), from: vi.fn() }));
vi.mock('@/integrations/supabase/client', () => ({ supabase: { rpc, from } }));
import { useAdminTableQuery } from '../useAdminTableQuery';

describe('admin users table', () => {
  it('uses the admin RPC for search, filters, sorting, paging and total count', async () => {
    rpc.mockResolvedValue({ data: { items: [{ id: 'user-1' }], total: 42 }, error: null });
    const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
    const wrapper = ({ children }: { children: ReactNode }) => (
      <QueryClientProvider client={client}>{children}</QueryClientProvider>
    );
    const { result } = renderHook(
      () =>
        useAdminTableQuery({
          tableName: 'profiles',
          state: {
            debouncedSearch: 'alex@example.org',
            filters: { is_online: false, moderation_status: 'suspended', user_mode: 'all' },
            sorting: { column: 'email', direction: 'asc' },
            pagination: { page: 2, pageSize: 50 },
          },
        }),
      { wrapper },
    );
    await waitFor(() => expect(result.current.totalCount).toBe(42));
    expect(result.current.data).toEqual([{ id: 'user-1' }]);
    expect(rpc).toHaveBeenCalledWith('admin_users_list', {
      p_search: 'alex@example.org',
      p_is_online: false,
      p_moderation_status: 'suspended',
      p_user_mode: undefined,
      p_sort: 'email',
      p_sort_asc: true,
      p_page: 2,
      p_per_page: 50,
    });
    expect(from).not.toHaveBeenCalled();
  });
});
