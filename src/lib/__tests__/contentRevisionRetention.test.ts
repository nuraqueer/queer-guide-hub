import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = process.cwd();
const MIGRATION = '99991792001788_content_revision_retention_and_heartbeat_noise.sql';
const strip = (sql: string) =>
  sql
    .split('\n')
    .filter((l) => !l.trim().startsWith('--'))
    .join('\n');
const sql = strip(readFileSync(join(ROOT, 'supabase/migrations', MIGRATION), 'utf8'));
const fnBody = sql.slice(
  sql.indexOf('CREATE OR REPLACE FUNCTION public.run_content_revision_prune'),
  sql.indexOf('REVOKE ALL'),
);

describe('content revision retention', () => {
  it('prunes only system rows, never human/declared', () => {
    expect(fnBody).toContain("actor_kind = 'system'");
    expect(fnBody).not.toMatch(/actor_kind\s*(<>|!=|IN)/i);
    expect((fnBody.match(/actor_kind/g) ?? []).length).toBe(2);
  });

  it('defaults to 21 days and a batch that outpaces ingest (~255k/day)', () => {
    const batch = Number(/p_batch\s+integer DEFAULT (\d+)/.exec(fnBody)?.[1]);
    const days = Number(/p_keep_days\s+integer DEFAULT (\d+)/.exec(fnBody)?.[1]);
    expect(days).toBeGreaterThanOrEqual(14);
    expect(days).toBeLessThanOrEqual(30);
    // hourly runs: 24 * batch must exceed the measured peak day (452k)
    expect(24 * batch).toBeGreaterThan(452_000);
  });

  it('registry and live cron are moved together, hourly, with the same command', () => {
    const cmd = /run_content_revision_prune\((\d+), (\d+)\);/g;
    const hits = [...sql.matchAll(cmd)].map((m) => `${m[1]},${m[2]}`);
    expect(hits.length).toBeGreaterThanOrEqual(2);
    expect(new Set(hits).size).toBe(1);
    expect(sql).toContain('UPDATE public.admin_automations');
    expect(sql).toContain('cron.alter_job');
    expect(sql.match(/'20 \* \* \* \*'/g)?.length).toBeGreaterThanOrEqual(2);
  });

  it('ignores the two heartbeat columns instead of excluding the tables', () => {
    expect(sql).toMatch(/\('marketplace_listings',\s*'quality_dimensions_at'\)/);
    expect(sql).toMatch(/\('events',\s*'last_verified_at'\)/);
    expect(sql).not.toMatch(/SET\s+enabled\s*=\s*false/i);
    // existing ignore list is unioned, not replaced
    expect(sql).toContain('t.ignore_columns || ARRAY[v.col]');
  });

  it('asserts its end state in the migration', () => {
    expect(sql).toMatch(/RAISE EXCEPTION 'prune defaults not applied/);
    expect(sql).toMatch(/RAISE EXCEPTION 'live cron and registry disagree/);
    expect(sql).toMatch(/RAISE EXCEPTION 'existing ignore_columns lost/);
  });

  it('CLAUDE.md no longer claims the 290 MB steady state', () => {
    const md = readFileSync(join(ROOT, 'CLAUDE.md'), 'utf8');
    expect(md).not.toContain('giving a steady state near 290 MB');
    expect(md).toContain('99991792001788');
  });

  it('health script horizon matches the 21d retention', () => {
    const h = readFileSync(join(ROOT, 'scripts/check-pipeline-health.mjs'), 'utf8');
    expect(h).toContain('horizon is 21d');
    expect(h).not.toContain('horizon is 90d');
  });
});
