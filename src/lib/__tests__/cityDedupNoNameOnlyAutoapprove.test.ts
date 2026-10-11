import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * The nightly sweep queued Winterhaven CA / Winter Haven FL (3,185 km apart) at
 * 0.85 as 'name_exact_no_geo' although both rows had coordinates, and the
 * auto-approve cron (default floor 0.80) merged it with no human. Asserted over
 * COMMENT-STRIPPED SQL: the header quotes every rule in prose.
 */

const MIGRATION = '99991791728202_city_dedup_no_name_only_autoapprove.sql';

const sql = readFileSync(join(process.cwd(), 'supabase', 'migrations', MIGRATION), 'utf8')
  .split('\n')
  .map((l) => l.replace(/--.*$/, ''))
  .join('\n');

const patch = sql.slice(sql.indexOf('$patch$'), sql.indexOf('$verify$'));
const verify = sql.slice(sql.indexOf('$verify$'));

describe('city dedup: no name-only auto-merge', () => {
  it('patches both live bodies, restating neither', () => {
    expect(patch).toContain("'public.run_dedup_truth_sweep(text,text,integer)'::regprocedure");
    expect(patch).toContain("'public.run_dedup_review_autoapprove(numeric,integer)'::regprocedure");
    expect(sql).not.toMatch(/create or replace function/i);
  });

  it('sweep vetoes a pair more than 50 km apart', () => {
    expect(patch).toContain(
      'and not coalesce(public.haversine_m(a.lat,a.lng,b.lat,b.lng) > 50000, false)\\n',
    );
    expect(patch).not.toMatch(/> 50000000/);
  });

  it('auto-approve never approves a city pair below 0.95', () => {
    expect(patch).toContain("AND NOT (q.entity_type = ''city'' AND q.confidence < 0.95)\\n");
  });

  it('refuses to patch when an anchor is not unique', () => {
    expect(patch).toMatch(/<> 1 then\s+raise exception 'sweep anchor/);
    expect(patch).toMatch(/<> 1 then\s+raise exception 'auto-approve anchor/);
  });

  it('postconditions raise for each half', () => {
    expect(verify).toMatch(/= 0 then\s+raise exception 'postcondition: sweep/);
    expect(verify).toMatch(/= 0 then\s+raise exception 'postcondition: auto-approve/);
  });
});
