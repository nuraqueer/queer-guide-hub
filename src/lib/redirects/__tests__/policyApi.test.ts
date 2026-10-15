import { describe, it, expect } from 'vitest';
import { policyPatchInput } from '../../../../supabase/functions/_shared/redirect-policy-api';
import { policyErrors, type LinkPolicy } from '../../../../supabase/functions/_shared/link-policy';
describe('policy patch contract', () => {
  it('preserves explicit top-level removals and password changes', () => {
    expect(policyPatchInput({ policy: { geo_targets: null, track_conversions: false } })).toEqual({
      patch: { geo_targets: null, track_conversions: false },
      changePassword: false,
      password: null,
    });
    expect(policyPatchInput({ password: null })).toEqual({
      patch: {},
      changePassword: true,
      password: null,
    });
    expect(policyPatchInput({ password: 'fixture-password' }).changePassword).toBe(true);
  });
  it.each([
    {},
    null,
    { policy: null },
    { policy: {} },
    { password: '' },
    { password: 'x'.repeat(257) },
    { password_hash: {} },
    { policy: { password_hash: null } },
    { policy: { expires_at: false } },
    { policy: { expired_target: 0 } },
    { policy: { device_targets: false } },
    { policy: { experiment: { variants: [null, null] } } },
    { policy: { experiment: [] } },
  ])('rejects invalid input without throwing incidental type errors: %j', (value) => {
    let error: unknown;
    try {
      policyPatchInput(value);
    } catch (caught) {
      error = caught;
    }
    expect(error).toBeInstanceOf(Error);
    expect(error).not.toBeInstanceOf(TypeError);
  });
  it('does not coerce malformed experiment weights into primitives', () => {
    const experiment = {
      starts_at: '2026-10-14T00:00:00Z',
      ends_at: '2026-10-28T00:00:00Z',
      variants: [
        { id: 'a', url: '/events', weight: { valueOf: 'invalid', toString: 'invalid' } },
        { id: 'b', url: '/city', weight: 50 },
      ],
    };
    let error: unknown;
    try {
      policyPatchInput({ policy: { experiment } });
    } catch (caught) {
      error = caught;
    }
    expect(error).toBeInstanceOf(Error);
    expect(error).not.toBeInstanceOf(TypeError);
  });
  it('validates complete replacement experiments and target URLs', () => {
    const experiment = {
      starts_at: '2026-10-14T00:00:00Z',
      ends_at: '2026-10-28T00:00:00Z',
      variants: [
        { id: 'a', url: '/events', weight: 50 },
        { id: 'b', url: '/city', weight: 50 },
      ],
    };
    expect(policyPatchInput({ policy: { experiment } }).patch.experiment).toEqual(experiment);
    expect(() => policyPatchInput({ policy: { geo_targets: { CH: 'http://127.0.0.1' } } })).toThrow(
      'destination',
    );
    expect(
      policyErrors({ experiment: { ...experiment, unexpected: true } } as unknown as LinkPolicy),
    ).toContain('Unknown A/B setting');
  });
});
