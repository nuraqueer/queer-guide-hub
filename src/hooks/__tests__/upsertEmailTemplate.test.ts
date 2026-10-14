import { beforeEach, describe, expect, it, vi } from 'vitest';
const api = vi.hoisted(() => ({
  from: vi.fn(),
  update: vi.fn(),
  eq: vi.fn(),
  select: vi.fn(),
  single: vi.fn(),
}));
vi.mock('@/integrations/supabase/client', () => ({ supabase: { from: api.from } }));
vi.mock('@/integrations/supabase/untyped', () => ({ untypedFrom: vi.fn() }));
vi.mock('@/lib/admin-audit', () => ({ logCmsAudit: vi.fn() }));
import { upsertEmailTemplate } from '../usePageFetchers';

describe('email template persistence confirmation', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    api.from.mockReturnValue({ update: api.update });
    api.update.mockReturnValue({ eq: api.eq });
    api.eq.mockReturnValue({ select: api.select });
    api.select.mockReturnValue({ single: api.single });
  });
  it('confirms a persisted row before reporting success', async () => {
    api.single.mockResolvedValue({ data: { id: 'fixture' }, error: null });
    expect((await upsertEmailTemplate({ subject: 'Saved subject' }, 'fixture')).error).toBeNull();
    expect(api.from).toHaveBeenCalledWith('email_templates');
    expect(api.eq).toHaveBeenCalledWith('id', 'fixture');
    expect(api.select).toHaveBeenCalledWith('id');
    expect(api.single).toHaveBeenCalledOnce();
  });
  it('preserves the server error for a zero-row or denied update', async () => {
    const error = { code: 'PGRST116', message: 'The result contains 0 rows' };
    api.single.mockResolvedValue({ data: null, error });
    expect((await upsertEmailTemplate({ subject: 'Unsaved' }, 'missing')).error).toBe(error);
  });
  it('rejects an empty response even if no server error was returned', async () => {
    api.single.mockResolvedValue({ data: null, error: null });
    expect((await upsertEmailTemplate({ subject: 'Unsaved' }, 'missing')).error?.message).toContain(
      'No email template was updated',
    );
  });
});
