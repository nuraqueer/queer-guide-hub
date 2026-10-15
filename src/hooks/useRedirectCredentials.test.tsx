import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { ReactNode } from 'react';
import { useRedirectCredentials } from './useRedirectCredentials';
const mocks = vi.hoisted(() => ({ userId: 'owner-a', invoke: vi.fn() }));
vi.mock('@/hooks/useAuth', () => ({ useAuth: () => ({ user: { id: mocks.userId } }) }));
vi.mock('@/integrations/supabase/client', () => ({
  supabase: { functions: { invoke: mocks.invoke } },
}));
beforeEach(() => {
  vi.clearAllMocks();
  mocks.userId = 'owner-a';
  mocks.invoke.mockImplementation(async () => ({
    data: { data: [{ id: mocks.userId, name: mocks.userId }], count: 1 },
    error: null,
  }));
});
function setup() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  const view = renderHook(() => useRedirectCredentials(), {
    wrapper: ({ children }: { children: ReactNode }) => (
      <QueryClientProvider client={client}>{children}</QueryClientProvider>
    ),
  });
  return { ...view, client };
}
describe('credential cache and secret lifecycle', () => {
  it('uses distinct account cache keys and discards unmounted metadata', async () => {
    const view = setup();
    await waitFor(() => expect(view.result.current.data?.[0].name).toBe('owner-a'));
    mocks.userId = 'owner-b';
    view.rerender();
    expect(view.result.current.data).toBeUndefined();
    await waitFor(() => expect(view.result.current.data?.[0].name).toBe('owner-b'));
    await waitFor(() =>
      expect(view.client.getQueryData(['redirect-api-credentials', 'owner-a'])).toBeUndefined(),
    );
    view.unmount();
    await waitFor(() =>
      expect(view.client.getQueryData(['redirect-api-credentials', 'owner-b'])).toBeUndefined(),
    );
  });
  it('aborts an unmounted creation and removes its pending entry from mutation cache', async () => {
    const view = setup();
    await waitFor(() => expect(view.result.current.isSuccess).toBe(true));
    let aborted = false;
    mocks.invoke.mockImplementation(
      (_path, options) =>
        new Promise((_resolve, reject) => {
          options.signal.addEventListener(
            'abort',
            () => {
              aborted = true;
              reject(new Error('Aborted'));
            },
            { once: true },
          );
        }),
    );
    let pending: Promise<unknown>;
    await act(async () => {
      pending = view.result.current.create
        .mutateAsync({ name: 'Test', expiresAt: '2030-01-01T00:00:00Z' })
        .catch(() => undefined);
    });
    await waitFor(() =>
      expect(mocks.invoke.mock.calls.some(([, options]) => options.body)).toBe(true),
    );
    view.unmount();
    await pending!;
    expect(aborted).toBe(true);
    await waitFor(() => expect(view.client.getMutationCache().getAll()).toHaveLength(0));
  });
  it('removes a successful one-time secret from the mutation cache after unmount', async () => {
    mocks.invoke.mockImplementation(async (_path, options) => ({
      data: options.body ? { secret: 'one-time-only' } : { data: [], count: 0 },
      error: null,
    }));
    const view = setup();
    await waitFor(() => expect(view.result.current.isSuccess).toBe(true));
    await act(async () => {
      await view.result.current.create.mutateAsync({
        name: 'Test',
        expiresAt: '2030-01-01T00:00:00Z',
      });
    });
    await waitFor(() => expect(view.result.current.create.data?.secret).toBe('one-time-only'));
    view.unmount();
    await waitFor(() => expect(view.client.getMutationCache().getAll()).toHaveLength(0));
  });
});
