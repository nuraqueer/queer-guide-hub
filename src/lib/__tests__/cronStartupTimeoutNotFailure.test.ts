import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * A pg_cron "job startup timeout" means the command never started. Projecting it
 * as an 'error' run counted it toward auto_pause_threshold=3, and three in 34
 * seconds on 2026-10-10 auto-paused search_reindex_drain — 28 hours of stale
 * site search and 269k queued reindexes. It is now 'partial', the same class as
 * a pg_net `timed_out`.
 *
 * Asserted against COMMENT-STRIPPED SQL: the header quotes the rule in prose,
 * so an unstripped check passes with the patch deleted.
 */

const MIGRATION = '99991791728081_cron_startup_timeout_not_a_failure.sql';

function stripSql(src: string): string {
  return src
    .split('\n')
    .map((line) => line.replace(/--.*$/, ''))
    .join('\n');
}

const sql = stripSql(
  readFileSync(join(process.cwd(), 'supabase', 'migrations', MIGRATION), 'utf8'),
);

const patch = sql.slice(sql.indexOf('$patch$'), sql.indexOf('$verify$'));
const verify = sql.slice(sql.indexOf('$verify$'));

describe('cron startup timeout is not a job failure', () => {
  it('patches the live body rather than restating it', () => {
    expect(patch).toContain(
      "pg_get_functiondef('public.admin_automation_project_cron_runs(integer)'::regprocedure)",
    );
    expect(patch).toMatch(/execute v_new;/);
    expect(sql).not.toMatch(/create or replace function public\.admin_automation_project_cron_runs/i);
  });

  it('projects a startup timeout as partial and a real failure as error', () => {
    expect(patch).toContain(
      "case when d.return_message = ''job startup timeout'' then ''partial'' else ''error'' end",
    );
  });

  it('does not count a startup timeout as an error', () => {
    expect(patch).toContain(
      "if d.return_message is distinct from ''job startup timeout'' then\\n          v_errors := v_errors + 1;",
    );
  });

  it('labels the run so the cause is visible on the row', () => {
    expect(patch).toContain("jsonb_build_object(''reason'', ''cron_startup_timeout'')");
  });

  it('refuses to patch when an anchor is not found exactly once', () => {
    for (const n of [1, 2, 3]) {
      expect(patch).toMatch(new RegExp(`<> 1 then\\s+raise exception 'anchor ${n}`));
    }
  });

  it('postconditions raise on each missing piece', () => {
    const raises = verify.match(/raise exception 'postcondition:/g) ?? [];
    expect(raises.length).toBe(4);
    expect(verify).toContain("else ''error'' end");
  });
});
