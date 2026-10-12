// @vitest-environment jsdom
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { BrandReviewQueue } from '../BrandReviewQueue';
const mocks = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock('@/integrations/supabase/untyped', () => ({ untypedSupabase: { rpc: mocks.rpc } }));
const brand = {
  id: 'brand1',
  display_name: 'Example Brand',
  brand_key: 'example',
  suggested_tags: ['queer_owned'],
  ownership_tags: [],
  confidence: 1,
  evidence: 'Verified source evidence',
  detection_source: 'admin',
  product_count: 10,
  top_source: null,
  sample_url: null,
};
function mount(evidence: string | null = 'Verified source evidence') {
  render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <BrandReviewQueue selectedBrand={{ ...brand, evidence }} />
    </QueryClientProvider>,
  );
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.rpc.mockResolvedValue({ data: null, error: null });
});
describe('selected brand ownership review', () => {
  it('keeps sensitive-claim confirmation before calling the protected approval RPC', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
    mount();
    fireEvent.click(await screen.findByRole('button', { name: 'Approve' }));
    expect(confirm).toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
    confirm.mockReturnValue(true);
    fireEvent.click(screen.getByRole('button', { name: 'Approve' }));
    await waitFor(() =>
      expect(mocks.rpc).toHaveBeenCalledWith(
        'approve_marketplace_brand',
        expect.objectContaining({ p_brand_id: 'brand1', p_tags: ['queer_owned'], p_confirm: true }),
      ),
    );
    confirm.mockRestore();
  });
  it('requires evidence for ownership claims without a stored source', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true);
    mount(null);
    fireEvent.click(await screen.findByRole('button', { name: 'Approve' }));
    await waitFor(() => expect(screen.getByRole('button', { name: 'Approve' })).toBeEnabled());
    expect(mocks.rpc).not.toHaveBeenCalled();
    confirm.mockRestore();
  });
});
