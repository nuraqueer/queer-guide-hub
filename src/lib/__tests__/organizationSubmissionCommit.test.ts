import { describe, expect, it } from 'vitest';
import { buildRecord } from '../../../supabase/functions/pipeline-commit/build-record';

describe('organisation submission commit', () => {
  it('preserves identity roles without forged claims, trust or location fields', () => {
    const record = buildRecord(
      'organizations',
      {
        name: 'Queer Support',
        description: 'An online support network.',
        metadata: {
          roles: ['support', 'community', 'bogus', 'support'],
          email: 'hello@example.com',
          claim_status: 'claimed',
          trust_score: 100,
          safety_gated: false,
          unknown_column: true,
        },
      },
      {},
      'organization',
    );
    expect(record.roles).toEqual(['support', 'community']);
    expect(record.email).toBe('hello@example.com');
    expect(record).not.toHaveProperty('claim_status');
    expect(record).not.toHaveProperty('trust_score');
    expect(record).not.toHaveProperty('unknown_column');
    expect(record.slug).toMatch(/^queer-support-[a-f0-9]{8}$/);
    expect(record).not.toHaveProperty('address');
  });
});
