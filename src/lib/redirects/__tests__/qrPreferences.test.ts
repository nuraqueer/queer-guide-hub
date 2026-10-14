import { beforeEach, describe, expect, it, vi } from 'vitest';
import { qrStylePreferenceInput } from '../../../../supabase/functions/_shared/redirect-qr-style';
import { readEffectiveQrStyles } from '../qrPreferences';
import { DEFAULT_QR_STYLE } from '../qr';
const mocks = vi.hoisted(() => ({ api: vi.fn() }));
vi.mock('../memberApi', () => ({ memberRedirectApi: mocks.api }));
beforeEach(() => vi.resetAllMocks());
describe('QR preference contracts', () => {
  it('accepts field removals/reset and rejects version, unknown, color and shape corruption', () => {
    expect(
      qrStylePreferenceInput({ version: null, style: { dots: 'joined', foreground: null } }),
    ).toEqual({ version: null, style: { dots: 'joined', foreground: null } });
    expect(qrStylePreferenceInput({ version: null, style: null })).toEqual({
      version: null,
      style: null,
    });
    for (const value of [
      { style: {} },
      { version: 'stale', style: {} },
      { version: null, style: { logo: 'https://example.org' } },
      { version: null, style: { dots: 'triangle' } },
      { version: null, style: { foreground: '#fff' } },
    ])
      expect(() => qrStylePreferenceInput(value)).toThrow();
  });
  it('passes cancellation, deduplicates IDs and rejects incomplete or duplicate effective-style results', async () => {
    const signal = new AbortController().signal;
    mocks.api.mockResolvedValue({
      data: [{ id: 'a', style: DEFAULT_QR_STYLE, source: 'workspace' }],
    });
    expect(await readEffectiveQrStyles(['a', 'a'], signal)).toHaveLength(1);
    expect(mocks.api).toHaveBeenCalledWith('/qr-styles/links?ids=a', 'GET', undefined, signal);
    for (const data of [
      [],
      [
        { id: 'a', style: DEFAULT_QR_STYLE, source: 'default' },
        { id: 'a', style: DEFAULT_QR_STYLE, source: 'default' },
      ],
      [{ id: 'other', style: DEFAULT_QR_STYLE, source: 'default' }],
      [{ id: 'a', style: { ...DEFAULT_QR_STYLE, foreground: '#ffffff' }, source: 'default' }],
    ]) {
      mocks.api.mockResolvedValue({ data });
      await expect(readEffectiveQrStyles(['a'])).rejects.toThrow('Invalid saved QR style');
    }
  });
});
