import { describe, expect, it } from 'vitest';
import { contentLinkHttpStatus, mayRemoveContentLink, nextContentLinkCheckCount } from '../../supabase/functions/_shared/content-link-state.ts';

describe('content link removal', () => {
  it.each([404, 410])('allows removal only after repeated HTTP %s', code => {
    expect(contentLinkHttpStatus(code)).toBe('BROKEN');
    expect(mayRemoveContentLink('BROKEN', code, 3)).toBe(false);
    expect(mayRemoveContentLink('BROKEN', code, 4)).toBe(true);
  });
  it.each([400, 401, 403, 405, 429, 451, 500, 502, 503, 504])('retains HTTP %s even after repeated checks', code => {
    expect(mayRemoveContentLink(contentLinkHttpStatus(code), code, 10)).toBe(false);
  });
  it('retains timeout, network and unsafe-target results without a confirmed HTTP status', () => {
    expect(mayRemoveContentLink('TIMEOUT', null, 10)).toBe(false);
    expect(mayRemoveContentLink('BROKEN', null, 10)).toBe(false);
  });

  it.each([
    ['TIMEOUT', null], ['BLOCKED', 429], ['BROKEN', 500], ['BROKEN', null],
  ])('starts a new dead-link sequence after %s/%s', (status, code) => {
    const count = nextContentLinkCheckCount(String(status), code as number | null, 3, 'BROKEN', 404);
    expect(count).toBe(1);
    expect(mayRemoveContentLink('BROKEN', 404, count)).toBe(false);
  });

  it('requires four confirmed-dead checks before removal', () => {
    let count = nextContentLinkCheckCount('PENDING', null, 0, 'BROKEN', 404);
    for (let check = 1; check <= 4; check++) {
      expect(mayRemoveContentLink('BROKEN', 404, count)).toBe(check === 4);
      if (check < 4) count = nextContentLinkCheckCount('BROKEN', 404, count, 'BROKEN', 410);
    }
  });

  it('breaks a dead-link sequence on a transient failure, without losing retry eligibility', () => {
    const transientCount = nextContentLinkCheckCount('BROKEN', 404, 3, 'TIMEOUT', 503);
    expect(transientCount).toBe(3);
    expect(nextContentLinkCheckCount('TIMEOUT', 503, transientCount, 'BROKEN', 404)).toBe(1);
    expect(nextContentLinkCheckCount('BROKEN', 404, 3, 'OK', 200)).toBe(0);
    expect(nextContentLinkCheckCount('BLOCKED', 429, 3, 'REDIRECT', 200)).toBe(0);
  });
});
