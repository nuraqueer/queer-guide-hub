// @vitest-environment jsdom
import { it, expect, vi } from 'vitest';
import { renderHook, waitFor, act } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import type { ReactNode } from 'react';
import { merchantListConfig } from '@/components/admin/business/organisationListConfigs';
const db = vi.hoisted(() => ({ from: vi.fn() }));
vi.mock('@/integrations/supabase/client', () => ({ supabase: { from: db.from } }));
import { useContentListController } from '../useContentListController';
function wrapper({ children }: { children: ReactNode }) {
  return <MemoryRouter>{children}</MemoryRouter>;
}
it('uses the protected operational source without a generic table query and refreshes when source records change', async () => {
  const initial = {
    rows: [{ id: 'm1', display_name: 'Before', is_enabled: true }],
    loading: false,
    refresh: vi.fn(),
  };
  const { result, rerender } = renderHook(
    ({ source }) =>
      useContentListController({ configOverride: merchantListConfig, source, operational: true }),
    { wrapper, initialProps: { source: initial } },
  );
  await waitFor(() => expect(result.current.items[0]?.title).toBe('Before'));
  expect(db.from).not.toHaveBeenCalled();
  act(() =>
    rerender({
      source: { ...initial, rows: [{ id: 'm1', display_name: 'After', is_enabled: true }] },
    }),
  );
  await waitFor(() => expect(result.current.items[0]?.title).toBe('After'));
  expect(db.from).not.toHaveBeenCalled();
});
