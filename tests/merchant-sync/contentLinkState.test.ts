import { describe, expect, it } from 'vitest';
import { contentLinkHttpStatus, mayRemoveContentLink } from '../../supabase/functions/_shared/content-link-state.ts';

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
});
