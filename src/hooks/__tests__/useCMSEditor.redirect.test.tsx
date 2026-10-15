import { beforeEach, describe, it, expect, vi } from 'vitest';
import { renderHook, act, waitFor } from '@testing-library/react';
const mocks = vi.hoisted(() => ({ api: vi.fn() }));
vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: { id: 'owner' } }) }));
vi.mock('@/hooks/use-toast', () => ({ toast: vi.fn() }));
vi.mock('@/lib/redirects/memberApi', () => ({ memberRedirectApi: mocks.api }));
vi.mock('@/components/admin/redirects/RedirectEventsPanel', () => ({
  RedirectEventsPanel: () => null,
}));
vi.mock('@/components/admin/redirects/RedirectToolbarActions', () => ({
  RedirectToolbarActions: () => null,
}));
vi.mock('@/config/contentTypeRegistry', async () => {
  const { redirectContentType } = await import('@/config/contentTypes/redirect');
  return { getContentType: () => redirectContentType };
});
vi.mock('@/integrations/supabase/client', () => ({
  supabase: {
    from: () => {
      const query = {
        select: () => query,
        eq: () => query,
        upsert: () => query,
        maybeSingle: async () => ({ data: null, error: null }),
      };
      return query;
    },
  },
}));
import { useCMSEditor } from '../useCMSEditor';
const row = {
  id: 'redirect-1',
  type: 'SHORT',
  slug: 'cms-fixture',
  target: '/events',
  domain_id: null,
  domain_hostname: null,
  match_kind: 'EXACT',
  status_code: 302,
  is_enabled: true,
  query_mode: 'PRESERVE',
  click_count: 0,
  click_limit: null,
  notes: 'Keep notes',
  start_at: null,
  end_at: null,
  query_override: null,
  utm_defaults: null,
  updated_at: '2026-10-14T00:00:00Z',
};
beforeEach(() => {
  vi.resetAllMocks();
  mocks.api.mockImplementation(
    async (_path: string, method?: string, body?: Record<string, unknown>) =>
      method ? { ...row, ...(body?.values as object), updated_at: '2026-10-14T00:01:00Z' } : row,
  );
});
describe('manual redirect CMS editor IO', () => {
  it('treats path conversion clears as submitted values rather than silently rejected fields', async () => {
    const { result } = renderHook(() => useCMSEditor({ contentType: 'redirects', itemId: row.id }));
    await waitFor(() => expect(result.current.state.data.slug).toBe('cms-fixture'));
    act(() =>
      result.current.setFields({
        type: 'PATH',
        source_path: '/converted-cms',
        domain_id: '00000000-0000-4000-8000-000000000001',
      }),
    );
    await act(async () => {
      expect(await result.current.save()).toBe(true);
    });
    expect(mocks.api).toHaveBeenLastCalledWith(
      '/manual-records/' + row.id,
      'PATCH',
      expect.objectContaining({
        expectedUpdatedAt: row.updated_at,
        values: {
          type: 'PATH',
          source_path: '/converted-cms',
          domain_id: null,
          slug: null,
          is_domain_root: false,
        },
      }),
    );
    expect(result.current.state.errors).toEqual({});
  });
  it('uses the atomic owner API for creation and subsequent updates with the returned timestamp', async () => {
    const onSaved = vi.fn();
    const { result } = renderHook(() =>
      useCMSEditor({
        contentType: 'redirects',
        onSaved,
        itemId: null,
        initialValues: { type: 'SHORT', slug: 'cms-fixture', target: '/events', domain_id: null },
      }),
    );
    await act(async () => {
      expect(await result.current.save()).toBe(true);
    });
    expect(mocks.api).toHaveBeenCalledWith(
      '/manual-records',
      'POST',
      expect.objectContaining({
        expectedUpdatedAt: null,
        values: expect.objectContaining({ slug: 'cms-fixture', domain_id: null }),
      }),
    );
    expect(result.current.state.itemId).toBe(row.id);
    expect(onSaved).toHaveBeenCalledWith(row.id);
    act(() => result.current.setField('notes', 'Edited notes'));
    await act(async () => {
      expect(await result.current.save()).toBe(true);
    });
    expect(mocks.api).toHaveBeenLastCalledWith('/manual-records/' + row.id, 'PATCH', {
      values: { notes: 'Edited notes' },
      expectedUpdatedAt: '2026-10-14T00:01:00Z',
    });
  });
  it('loads the owner API and retains unsaved fields on a stale-write refusal', async () => {
    const { result } = renderHook(() => useCMSEditor({ contentType: 'redirects', itemId: row.id }));
    await waitFor(() => expect(result.current.state.data.slug).toBe('cms-fixture'));
    expect(mocks.api).toHaveBeenCalledWith('/manual-records/' + row.id);
    act(() => result.current.setField('target', '/changed'));
    mocks.api.mockRejectedValueOnce(new Error('Redirect changed; reload before saving'));
    await act(async () => {
      expect(await result.current.save()).toBe(false);
    });
    expect(result.current.state.data.target).toBe('/changed');
    expect(result.current.state.isDirty).toBe(true);
  });
});
