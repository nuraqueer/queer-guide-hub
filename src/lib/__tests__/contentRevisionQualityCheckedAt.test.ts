import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const MIGRATION = '99991792224383_content_revision_ignore_quality_checked_at.sql';
const sql = readFileSync(join(process.cwd(), 'supabase/migrations', MIGRATION), 'utf8')
  .split('\n')
  .filter((l) => !l.trim().startsWith('--'))
  .join('\n');

describe('content revision heartbeat filter, round two', () => {
  it('adds quality_checked_at to exactly the two heartbeat-dominated tables', () => {
    expect(sql).toMatch(/WHERE t\.table_name IN \('marketplace_brands', 'organizations'\);/);
    expect(sql).toContain("t.ignore_columns || ARRAY['quality_checked_at']");
  });

  it('unions into the existing ignore list instead of replacing it', () => {
    expect(sql).toContain('t.ignore_columns ||');
    expect(sql).not.toMatch(/SET ignore_columns = ARRAY\[/);
  });

  it('does not ignore real-value columns or switch tables off', () => {
    expect(sql).not.toMatch(/quality_score|trust_score|completeness_score/);
    expect(sql).not.toMatch(/enabled\s*=\s*false/i);
  });

  it('asserts end state: column ignored, updated_at kept, tables still enabled', () => {
    expect(sql).toContain(
      "'quality_checked_at' = ANY (ignore_columns) AND 'updated_at' = ANY (ignore_columns)",
    );
    expect(sql).toMatch(/RAISE EXCEPTION 'quality_checked_at not ignored/);
    expect(sql).toMatch(/RAISE EXCEPTION 'marketplace_brands\/organizations must stay enabled'/);
  });
});
