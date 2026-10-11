/** @vitest-environment jsdom */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { act, renderHook, waitFor } from '@testing-library/react';

const { rpc } = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: { id: 'editor' } }) }));
vi.mock('@/hooks/use-toast', () => ({ toast: vi.fn() }));
vi.mock('@/integrations/supabase/untyped', () => ({ untypedRpc: rpc }));
vi.mock('@/integrations/supabase/client', () => ({
  supabase: {
    from: () => {
      const chain = {
        select: () => chain,
        eq: () => chain,
        upsert: () => chain,
        maybeSingle: async () => ({ data: null, error: null }),
      };
      return chain;
    },
  },
}));
vi.mock('@/config/contentTypeRegistry', async () => {
  const { organizationContentType } = await import('@/config/contentTypes/organization');
  return { getContentType: () => organizationContentType };
});
import { useCMSEditor } from '../useCMSEditor';

const identity = {
  id: 'org-1',
  name: 'Support network',
  roles: ['support'],
  status: 'draft',
  updated_at: '2026-10-11T10:00:00Z',
  _locations: [],
  social: {},
  images: [],
  tags: [],
  target_groups: [],
  is_defunct: false,
};

describe('transactional organisation editor', () => {
  beforeEach(() => {
    rpc.mockReset();
  });

  it('creates an addressless identity then updates the returned ID on the next save', async () => {
    rpc.mockImplementation(async (_name, args) => ({
      data: { ...identity, ...args.p_data, updated_at: identity.updated_at },
      error: null,
    }));
    const { result } = renderHook(() =>
      useCMSEditor({
        contentType: 'organizations',
        itemId: null,
        initialValues: { name: identity.name, roles: ['support'] },
      }),
    );
    await act(async () => {
      expect(await result.current.save()).toBe(true);
    });
    expect(rpc).toHaveBeenLastCalledWith(
      'cms_organisation_save',
      expect.objectContaining({ p_id: null, p_locations: [] }),
    );
    expect(result.current.state.itemId).toBe('org-1');
    act(() => result.current.setField('description', 'Updated copy'));
    await act(async () => {
      expect(await result.current.save()).toBe(true);
    });
    expect(rpc).toHaveBeenLastCalledWith(
      'cms_organisation_save',
      expect.objectContaining({
        p_id: 'org-1',
        p_locations: null,
        p_expected_updated_at: identity.updated_at,
      }),
    );
  });

  it('loads nested locations and sends location edits in the same RPC as identity edits', async () => {
    const location = {
      id: 'branch-1',
      name: 'Example bar',
      address: 'Example Street',
      city: 'Zurich',
      country: 'Switzerland',
      category: 'bar',
      updated_at: identity.updated_at,
    };
    rpc.mockImplementation(async (_name, args) => ({
      data: {
        ...identity,
        roles: ['venue'],
        ...args.p_data,
        _locations: args.p_locations ?? [location],
        updated_at: identity.updated_at,
      },
      error: null,
    }));
    const { result } = renderHook(() =>
      useCMSEditor({ contentType: 'organizations', itemId: 'org-1' }),
    );
    await waitFor(() => expect(result.current.state.isLoading).toBe(false));
    act(() =>
      result.current.setFields({
        description: 'Identity edit',
        _locations: [{ ...location, address: 'Changed Street' }],
      }),
    );
    await act(async () => {
      expect(await result.current.save()).toBe(true);
    });
    expect(rpc).toHaveBeenLastCalledWith(
      'cms_organisation_save',
      expect.objectContaining({
        p_data: expect.objectContaining({ description: 'Identity edit' }),
        p_locations: [expect.objectContaining({ id: 'branch-1', address: 'Changed Street' })],
      }),
    );
    expect(rpc.mock.calls.at(-1)?.[1].p_data).not.toHaveProperty('_locations');
  });

  it('refreshes workflow timestamps without discarding pending identity edits', async () => {
    rpc.mockResolvedValueOnce({ data: identity, error: null });
    const { result } = renderHook(() =>
      useCMSEditor({ contentType: 'organizations', itemId: 'org-1' }),
    );
    await waitFor(() => expect(result.current.state.isLoading).toBe(false));
    act(() => result.current.setField('description', 'Unsaved text'));
    const published = { ...identity, status: 'active', updated_at: '2026-10-11T11:00:00Z' };
    rpc.mockResolvedValueOnce({ data: published, error: null });
    await act(async () => {
      await result.current.refresh();
    });
    expect(result.current.state.data.description).toBe('Unsaved text');
    expect(result.current.state.data.status).toBe('active');
    expect(result.current.state.isDirty).toBe(true);
    rpc.mockImplementation(async (_name, args) => ({
      data: { ...published, ...args.p_data },
      error: null,
    }));
    await act(async () => {
      expect(await result.current.save()).toBe(true);
    });
    expect(rpc).toHaveBeenLastCalledWith(
      'cms_organisation_save',
      expect.objectContaining({ p_expected_updated_at: published.updated_at }),
    );
  });

  it('keeps unsaved edits when the transaction fails', async () => {
    rpc.mockResolvedValueOnce({ data: identity, error: null });
    const { result } = renderHook(() =>
      useCMSEditor({ contentType: 'organizations', itemId: 'org-1' }),
    );
    await waitFor(() => expect(result.current.state.isLoading).toBe(false));
    act(() => result.current.setField('description', 'Keep this edit'));
    rpc.mockResolvedValueOnce({
      data: null,
      error: { message: 'A location was modified by someone else.' },
    });
    await act(async () => {
      expect(await result.current.save()).toBe(false);
    });
    expect(result.current.state.isDirty).toBe(true);
    expect(result.current.state.data.description).toBe('Keep this edit');
    expect(result.current.state.errors._save).toContain('modified');
  });
});
