import { webcrypto } from 'node:crypto';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  redirectClientIp,
  signRedirectRelay,
} from '../../../../supabase/functions/_shared/redirect-relay';
afterEach(() => vi.unstubAllGlobals());
describe('authenticated redirect visitor relay', () => {
  it('accepts a recent signed relay, but rejects spoofing, altered slugs, time and secrets', async () => {
    vi.stubGlobal('crypto', webcrypto);
    const secret = 'a'.repeat(32),
      now = 1791930000000;
    const relay = await signRedirectRelay('192.0.2.1', 'pride-link', secret, now);
    const headers = new Headers({
      'cf-connecting-ip': '192.0.2.2',
      'x-forwarded-for': 'spoofed',
      'x-qg-relay-ip': relay!.ip,
      'x-qg-relay-time': relay!.timestamp,
      'x-qg-relay-signature': relay!.signature,
    });
    expect(await redirectClientIp(headers, 'pride-link', secret, now)).toBe('192.0.2.1');
    expect(await redirectClientIp(headers, 'other-link', secret, now)).toBe('192.0.2.2');
    expect(await redirectClientIp(headers, 'pride-link', 'b'.repeat(32), now)).toBe('192.0.2.2');
    expect(await redirectClientIp(headers, 'pride-link', secret, now + 121000)).toBe('192.0.2.2');
    expect(await redirectClientIp(headers, 'pride-link', undefined, now)).toBe('192.0.2.2');
    headers.set('x-qg-relay-ip', 'spoofed');
    expect(await redirectClientIp(headers, 'pride-link', secret, now)).toBe('192.0.2.2');
    expect(await signRedirectRelay('192.0.2.1', 'pride-link', 'short', now)).toBeNull();
  });
});
