import { webcrypto } from 'node:crypto';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  chooseLinkTarget,
  deviceFromAgent,
  experimentWinner,
  hashLinkPassword,
  policyErrors,
  validPublicTarget,
  verifyLinkPassword,
  type LinkPolicy,
} from '../../../../supabase/functions/_shared/link-policy';

afterEach(() => vi.unstubAllGlobals());
const experiment = {
  starts_at: '2026-10-01T00:00:00Z',
  ends_at: '2026-10-15T00:00:00Z',
  variants: [
    { id: 'a', url: 'https://example.com/a', weight: 70 },
    { id: 'b', url: 'https://example.com/b', weight: 30 },
  ],
};
describe('link policies', () => {
  it('uses device before country before weighted experiment, then the fallback', () => {
    const policy: LinkPolicy = {
      device_targets: { ios: '/ios' },
      geo_targets: { CH: '/swiss' },
      experiment,
    };
    const context = { now: Date.parse('2026-10-13'), device: 'ios', country: 'CH', bucket: 90 };
    expect(chooseLinkTarget('/default', policy, context).target).toBe('/ios');
    expect(chooseLinkTarget('/default', policy, { ...context, device: 'desktop' }).target).toBe(
      '/swiss',
    );
    expect(
      chooseLinkTarget('/default', policy, {
        ...context,
        device: 'desktop',
        country: 'DE',
        bucket: 69,
      }).variantId,
    ).toBe('a');
    expect(
      chooseLinkTarget('/default', policy, {
        ...context,
        device: 'desktop',
        country: 'DE',
        bucket: 70,
      }).variantId,
    ).toBe('b');
    expect(chooseLinkTarget('/default', {}, context).target).toBe('/default');
  });
  it('honors expiry before targeting, with optional fallback', () => {
    expect(
      chooseLinkTarget(
        '/default',
        { expires_at: '2026-10-01', expired_target: '/expired', device_targets: { ios: '/ios' } },
        { device: 'ios', bucket: 0, now: Date.parse('2026-10-13') },
      ),
    ).toMatchObject({ expired: true, target: '/expired' });
    expect(
      chooseLinkTarget(
        '/default',
        { expires_at: '2026-10-01' },
        { device: 'desktop', bucket: 0, now: Date.parse('2026-10-13') },
      ),
    ).toMatchObject({ expired: true, target: null });
  });
  it('selects the winner using sales, then rates, then clicks; otherwise leads', () => {
    expect(
      experimentWinner(experiment.variants, [
        { id: 'a', clicks: 100, leads: 8, sales: 2 },
        { id: 'b', clicks: 10, leads: 4, sales: 2 },
      ]),
    ).toBe('https://example.com/b');
    expect(
      experimentWinner(experiment.variants, [
        { id: 'a', clicks: 100, leads: 3, sales: 0 },
        { id: 'b', clicks: 10, leads: 4, sales: 0 },
      ]),
    ).toBe('https://example.com/b');
    expect(
      chooseLinkTarget(
        '/default',
        { experiment: { ...experiment, completed_target: '/selected' } },
        { device: 'desktop', bucket: 0 },
      ).target,
    ).toBe('/selected');
  });
  it('rejects invalid weights, durations, schemes, credentials and private hosts', () => {
    expect(policyErrors({ experiment })).toEqual([]);
    expect(
      policyErrors({
        experiment: {
          ...experiment,
          variants: experiment.variants.map((variant) => ({ ...variant, weight: 5 })),
        },
      }).join(' '),
    ).toContain('100%');
    expect(
      policyErrors({ experiment: { ...experiment, ends_at: '2027-01-01' } }).join(' '),
    ).toContain('6 weeks');
    expect(validPublicTarget('https://example.com/product?utm_source=qr')).toBe(true);
    for (const target of [
      '//example.com',
      '/\\example.com',
      'javascript:alert(1)',
      'ftp://example.com',
      'https://user:pass@example.com',
      'http://localhost',
      'http://127.0.0.1',
      'http://192.168.1.4',
    ])
      expect(validPublicTarget(target)).toBe(false);
  });
  it('classifies native and desktop agents', () => {
    expect(deviceFromAgent('Mozilla iPad')).toBe('ios');
    expect(deviceFromAgent('Mozilla Macintosh Mobile')).toBe('ios');
    expect(deviceFromAgent('Mozilla Android')).toBe('android');
    expect(deviceFromAgent('Mozilla Windows')).toBe('desktop');
  });
  it('stores salted password hashes, verifies correctly, and rejects malformed formats', async () => {
    vi.stubGlobal('crypto', webcrypto);
    const first = await hashLinkPassword('test-only password'),
      second = await hashLinkPassword('test-only password');
    expect(first.hash).not.toBe(second.hash);
    expect(JSON.stringify(first)).not.toContain('test-only password');
    expect(await verifyLinkPassword('test-only password', first)).toBe(true);
    expect(await verifyLinkPassword('wrong', first)).toBe(false);
    expect(await verifyLinkPassword('test-only password', { ...first, iterations: 1 })).toBe(false);
  });
});
