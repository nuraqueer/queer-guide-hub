/** @vitest-environment jsdom */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { act, renderHook } from '@testing-library/react';

const { invoke, toast, order } = vi.hoisted(() => ({
  invoke: vi.fn(),
  toast: vi.fn(),
  order: vi.fn(),
}));
vi.mock('@/hooks/use-toast', () => ({ useToast: () => ({ toast }) }));
vi.mock('@/integrations/supabase/client', () => ({
  supabase: {
    functions: { invoke },
    rpc: vi.fn().mockResolvedValue({ data: {}, error: null }),
    from: (table: string) => ({
      select: () => ({
        order:
          table === 'ingestion_sources'
            ? order
            : () => ({ limit: () => Promise.resolve({ data: [], error: null }) }),
      }),
    }),
  },
}));
import { useImportHub, type IngestionSource } from '../useImportHub';

beforeEach(() => {
  invoke.mockReset();
  toast.mockReset();
  order.mockResolvedValue({ data: [], error: null });
});

describe('useImportHub source failures', () => {
  it('propagates query errors so the source manager can show a retry', async () => {
    order.mockResolvedValue({ data: null, error: new Error('offline') });
    const { result } = renderHook(() => useImportHub());
    await expect(result.current.fetchSources()).rejects.toThrow('offline');
  });

  it.each([
    [{ success: true, skipped: true, reason: 'missing_credentials' }, 'Source skipped'],
    [{ success: false, error: 'provider unavailable' }, 'Trigger Failed'],
  ])('does not announce a successful run for %j', async (data, title) => {
    invoke.mockResolvedValue({ data, error: null });
    const { result } = renderHook(() => useImportHub());
    await act(async () => {
      await result.current.triggerSource({
        id: 'source',
        name: 'Test provider',
        edge_function: 'source-test',
      } as IngestionSource);
    });
    expect(toast).toHaveBeenCalledWith(expect.objectContaining({ title, variant: 'destructive' }));
    expect(toast).not.toHaveBeenCalledWith(expect.objectContaining({ title: 'Source Triggered' }));
  });
});
