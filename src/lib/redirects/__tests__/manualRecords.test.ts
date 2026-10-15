import { describe, it, expect, vi, beforeEach } from 'vitest';
import { manualRedirectInput } from '../../../../supabase/functions/_shared/redirect-manual-records';
import { manualRedirectValues, saveManualRedirect } from '../manualRecords';
const mocks = vi.hoisted(() => ({ api: vi.fn() }));
vi.mock('../memberApi', () => ({ memberRedirectApi: mocks.api }));
beforeEach(() => vi.resetAllMocks());
describe('manual record contract', () => {
  it('accepts a manual domain homepage without a slug and keeps its typed root flag', () => {
    const value = {
      type: 'SHORT',
      domain_id: '00000000-0000-4000-8000-000000000001',
      is_domain_root: true,
      target: '/events',
    };
    expect(manualRedirectInput(value, true)).toMatchObject(value);
  });
  it('maps shared validation while preserving typed manual path and query fields', () => {
    expect(
      manualRedirectInput(
        {
          type: 'PATH',
          source_path: '/old/*',
          match_kind: 'WILDCARD',
          target: '/events',
          start_at: '2026-01-01T10:00:00+02:00',
          click_limit: 4,
          notes: 'A note',
          query_override: { audience: 'friends' },
        },
        true,
      ),
    ).toMatchObject({
      source_path: '/old/*',
      start_at: '2026-01-01T08:00:00.000Z',
      click_limit: 4,
      domain_id: null,
      slug: null,
    });
  });
  it('rejects system columns, unsafe targets, invalid paths and malformed settings before a write', () => {
    for (const values of [
      { click_count: 0 },
      { created_by: 'actor' },
      { target: 'http://127.0.0.1' },
      { source_path: '//evil.example' },
      { click_limit: 0 },
      { start_at: 'invalid' },
      { type: 'PATH', domain_id: '00000000-0000-4000-8000-000000000001' },
      { type: 'SHORT', slug: 'admin' },
    ])
      expect(() => manualRedirectInput(values, false)).toThrow();
    expect(() => manualRedirectInput({ type: 'PATH', source_path: '/old' }, true)).toThrow(
      'destination',
    );
  });
  it('normalizes conversion clears and excludes generated fields without mutating its caller', () => {
    const data = {
      type: 'PATH',
      source_path: '/old',
      slug: 'old-slug',
      domain_id: 'domain',
      click_count: 18,
      created_by: 'actor',
    };
    expect(manualRedirectValues(data)).toEqual({
      type: 'PATH',
      is_domain_root: false,
      source_path: '/old',
      slug: null,
      domain_id: null,
    });
    expect(data.domain_id).toBe('domain');
    expect(
      manualRedirectValues({
        type: 'SHORT',
        slug: 'new-slug',
        source_path: '/old',
        match_kind: 'REGEX',
      }),
    ).toEqual({ type: 'SHORT', slug: 'new-slug', source_path: null, match_kind: 'EXACT' });
  });
  it('sends the loaded version separately from writable fields', async () => {
    await saveManualRedirect(
      'record',
      { notes: 'Keep', updated_at: 'client-value', click_count: 0 },
      'server-time',
    );
    expect(mocks.api).toHaveBeenCalledWith('/manual-records/record', 'PATCH', {
      values: { notes: 'Keep' },
      expectedUpdatedAt: 'server-time',
    });
  });
});
