import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const sql = readFileSync(
  join(process.cwd(), 'supabase/migrations/99991792747676_org_safety_gate_follows_venue_merge.sql'),
  'utf8',
)
  .split('\n')
  .filter((l) => !/^\s*--/.test(l))
  .join('\n');

const fnBody = sql.slice(sql.indexOf('as $fn$'), sql.indexOf('end $fn$'));

describe('org safety gate follows a venue merge', () => {
  it('re-decides the org when the primary venue is merged away', () => {
    expect(sql).toMatch(/after update of safety_gated, duplicate_of_id on public\.venues/);
    expect(sql).toMatch(/old\.duplicate_of_id is distinct from new\.duplicate_of_id/);
    expect(sql).toMatch(/old\.safety_gated is distinct from new\.safety_gated/);
  });

  it('covers merged organizations too, as the gate arm does', () => {
    expect(fnBody).toContain('where o.primary_venue_id = new.id');
    expect(fnBody).not.toContain('duplicate_of_id');
  });

  it('heals through the seal and asserts by raising', () => {
    expect(sql).toMatch(/set primary_venue_id = o\.primary_venue_id\s*\n\s*from c/);
    expect(sql).not.toMatch(/set safety_gated\s*=/);
    expect([...sql.matchAll(/raise exception 'P[123] failed/g)].length).toBe(3);
  });
});
