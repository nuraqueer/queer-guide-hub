import { describe, expect, it, vi } from 'vitest';
import { webcrypto } from 'node:crypto';
import {
  conversionInput,
  createRedirectToken,
  tokenDigest,
} from '../../../../supabase/functions/_shared/redirect-api';
import {
  amountMicros,
  currencyRevenue,
  formatRevenue,
  type RedirectConversion,
} from '../conversions';
import {
  captureRedirectAttribution,
  clearRedirectAttribution,
  readRedirectAttribution,
} from '../attribution';
const click = '00000000-0000-4000-8000-000000000001';
const base = { clickId: click, customerExternalId: 'customer', eventId: 'checkout:123' };
describe('conversion contract', () => {
  it('validates attributed leads and customer-attributed sales with exact decimal amounts', () => {
    expect(
      conversionInput({ ...base, amount: '999999999999.999999', currency: 'CHF' }, 'sale').amount,
    ).toBe('999999999999.999999');
    expect(conversionInput(base, 'lead')).toMatchObject({ kind: 'lead', eventName: 'Lead' });
    expect(conversionInput({ ...base, amount: 49.9, currency: 'CHF' }, 'sale')).toMatchObject({
      amount: 49.9,
      eventName: 'Sale',
    });
    expect(
      conversionInput(
        { customerExternalId: 'customer', eventId: 'renewal:456', amount: 0, currency: 'USD' },
        'sale',
      ).clickId,
    ).toBeUndefined();
    for (const value of [-1, NaN, Infinity, 1e12, 0.0000001])
      expect(() => conversionInput({ ...base, amount: value, currency: 'CHF' }, 'sale')).toThrow();
    expect(() => conversionInput({ ...base, amount: 10, currency: 'chf' }, 'sale')).toThrow();
    expect(() => conversionInput({ ...base, amount: 0 }, 'lead')).toThrow();
    expect(() => conversionInput({ ...base, clickId: 'forged' }, 'lead')).toThrow();
    expect(() => conversionInput({ ...base, metadata: [] }, 'lead')).toThrow();
    expect(() =>
      conversionInput({ ...base, metadata: { value: 'x'.repeat(9000) } }, 'lead'),
    ).toThrow();
  });
  it('uses 256-bit random credentials, unique hashes, and no recoverable raw secret', async () => {
    vi.stubGlobal('crypto', webcrypto);
    try {
      const a = createRedirectToken(),
        b = createRedirectToken();
      expect(a).toMatch(/^qg_redirect_[a-f0-9]{64}$/);
      expect(a).not.toBe(b);
      expect(await tokenDigest(a)).toMatch(/^[a-f0-9]{64}$/);
      expect(await tokenDigest(a)).not.toBe(await tokenDigest(b));
    } finally {
      vi.unstubAllGlobals();
    }
  });
  it('keeps currencies separate and accumulates exact fractions without floating-point loss', () => {
    const sale = (amount: string, currency: string) =>
      ({ kind: 'sale', amount, currency }) as RedirectConversion;
    expect(currencyRevenue([sale('0.1', 'CHF'), sale('0.2', 'CHF'), sale('10.01', 'EUR')])).toEqual(
      [
        ['CHF', 300000n],
        ['EUR', 10010000n],
      ],
    );
    expect(amountMicros('999999999999.999999')).toBe(999999999999999999n);
    expect(formatRevenue(300000n, 'CHF')).toMatch(/0[.,]30/);
    expect(formatRevenue(1250000n, 'JPY')).toMatch(/1/);
  });
});
describe('consented click attribution', () => {
  it('stores last click for 30 days, rejects invalid IDs, expires and removes storage on withdrawal', () => {
    localStorage.clear();
    const now = 1000000000,
      url = new URL('https://queer.guide/events?qg_click_id=' + click);
    expect(captureRedirectAttribution(url, false, localStorage, now)).toBe(false);
    expect(readRedirectAttribution(true, localStorage, now)).toBeNull();
    expect(captureRedirectAttribution(url, true, localStorage, now)).toBe(true);
    expect(readRedirectAttribution(true, localStorage, now)?.clickId).toBe(click);
    const newer = '00000000-0000-4000-8000-000000000002';
    url.searchParams.set('qg_click_id', newer);
    captureRedirectAttribution(url, true, localStorage, now + 1);
    expect(readRedirectAttribution(true, localStorage, now + 1)?.clickId).toBe(newer);
    expect(readRedirectAttribution(true, localStorage, now + 30 * 86400000 + 2)).toBeNull();
    expect(
      captureRedirectAttribution(new URL('https://queer.guide/?qg_click_id=invalid'), true),
    ).toBe(false);
    captureRedirectAttribution(url, true, localStorage, now);
    expect(readRedirectAttribution(false, localStorage, now)).toBeNull();
    clearRedirectAttribution();
  });
});
