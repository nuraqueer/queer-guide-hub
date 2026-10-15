import { describe, expect, it } from 'vitest';
import {
  visitorAgent,
  visitorMetadata,
} from '../../../../supabase/functions/_shared/redirect-visitor';
import { analyticsFilters } from '../../../../supabase/functions/_shared/redirect-analytics';
import { analyticsCsv, utcDateRange, type AnalyticsEvent } from '../analytics';
import { qrTrackingUrl } from '../qr';
describe('visitor dimensions and QR attribution', () => {
  it('recognizes browser/OS families, phones, tablets and bots without inventing versions', () => {
    expect(
      visitorAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile Safari/604.1'),
    ).toMatchObject({ device: 'Mobile', browser: 'Safari', os: 'iOS', is_bot: false });
    expect(
      visitorAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X) Mobile Safari/604.1'),
    ).toMatchObject({ device: 'Tablet', os: 'iOS' });
    expect(visitorAgent('Mozilla/5.0 (Windows NT 10.0) Chrome/130.0 Edg/130.0')).toMatchObject({
      browser: 'Edge',
      os: 'Windows',
    });
    expect(visitorAgent('Googlebot Chrome/130.0')).toMatchObject({ device: 'Bot', is_bot: true });
    expect(visitorAgent(null)).toMatchObject({
      device: 'Unknown',
      browser: 'Unknown',
      os: 'Unknown',
    });
  });
  it('uses bounded relay metadata and distinguishes a QR visit from a link visit', () => {
    const req = new Request('https://fixture.supabase.co', {
      headers: {
        'x-qg-visitor-city': 'Zurich',
        'x-qg-visitor-domain': 'queer.guide',
        'user-agent': 'Mozilla/5.0 (Android) Chrome/130.0 Mobile',
      },
    });
    expect(visitorMetadata(req, true)).toMatchObject({
      city: 'Zurich',
      domain: 'queer.guide',
      is_qr: true,
      device: 'Mobile',
      browser: 'Chrome',
    });
    expect(qrTrackingUrl('https://queer.guide/go/pride?utm_source=poster#details')).toBe(
      'https://queer.guide/go/pride?utm_source=poster&qg_qr=1#details',
    );
    expect(qrTrackingUrl('https://example.com/page')).toBe('https://example.com/page');
  });
});
describe('analytics filter and export contracts', () => {
  it('validates closed filters and complete UTC date windows', () => {
    const filters = {
      event: 'sale',
      excludeBots: true,
      interval: 'month',
      linkIds: ['00000000-0000-4000-8000-000000000001'],
    };
    expect(analyticsFilters(filters)).toEqual(filters);
    expect(() => analyticsFilters({ unknown: 'value' })).toThrow();
    expect(() => analyticsFilters({ linkIds: ['fake'] })).toThrow();
    expect(() => analyticsFilters({ qr: 'true' })).toThrow();
    expect(utcDateRange('2026-10-01', '2026-10-14')).toEqual({
      start: '2026-10-01T00:00:00.000Z',
      end: '2026-10-15T00:00:00.000Z',
    });
    expect(() => utcDateRange('2026-10-14', '2026-10-01')).toThrow();
  });
  it('exports exact amount strings, escapes quotes and neutralizes spreadsheet formulas', () => {
    const event = {
      id: 'event',
      kind: 'sale',
      event_name: '=EXEC()',
      customer_key: '"quoted"',
      amount: '999999999999.999999',
      currency: 'CHF',
    } as AnalyticsEvent;
    const csv = analyticsCsv([event]);
    expect(csv).toContain('"\'=EXEC()"');
    expect(csv).toContain('""quoted""');
    expect(csv).toContain('999999999999.999999');
    expect(csv).not.toContain('ip_hash');
    expect(csv).not.toContain('user_agent');
  });
});
