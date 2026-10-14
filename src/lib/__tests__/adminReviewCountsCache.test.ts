import { describe, expect, it } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const MIGRATION = '99991791999590_admin_review_counts_cache.sql';
const MIGRATIONS = join(process.cwd(), 'supabase', 'migrations');
const HEALTH = join(process.cwd(), 'scripts', 'check-pipeline-health.mjs');

const raw = readFileSync(join(MIGRATIONS, MIGRATION), 'utf8');

// EVERY assertion runs over comment-STRIPPED source. This migration's header
// quotes, verbatim and at length, the per-source EXISTS shape it rejects, the
// `admin_automation_run_begin` assertion it removed, and the live/cached
// `total` mix it refuses -- so an unstripped `toContain` would match the prose
// while the executable statement was gone. Line-anchored, because a mid-line
// `--` inside a string literal is not a comment.
const sql = raw
  .split('\n')
  .filter((l) => !/^\s*--/.test(l))
  .join('\n');

/** Everything the migration executes, with its own verify block cut off: that
 *  block legitimately greps for the same phrases the statements must contain,
 *  so an assertion over the whole file passes with a statement deleted. */
const statements = sql.slice(0, sql.indexOf('do $verify$'));
const verify = sql.slice(sql.indexOf('do $verify$'));

const occurrences = (haystack: string, needle: string) => haystack.split(needle).length - 1;

describe('the review counts cache migration is present and sorts above the applied ceiling', () => {
  it('exists under its own name', () => {
    expect(readdirSync(MIGRATIONS)).toContain(MIGRATION);
  });

  it('carries a 14-digit version allocated by the clock, not picked by hand', () => {
    expect(MIGRATION).toMatch(/^9999\d{10}_/);
  });
});

describe('the refresh keeps the ONE-union shape and never the per-source aggregate', () => {
  // The per-source form is not a style preference: `count(*) filter (where
  // exists (...))` is an aggregate FILTER expression, so it cannot be planned
  // as a semi-join and does the admin_review_finding_codes join 41 times
  // instead of once. Measured at >60s against ~6.9s for the union shape, and
  // separately at 8.03s -- worse than the unpatched function -- while choosing
  // between candidate fixes. It was rebuilt and shipped once by accident.
  it('joins admin_review_finding_codes exactly once, as a LEFT JOIN', () => {
    const fn = statements.slice(
      statements.indexOf('function public.refresh_admin_review_queue_counts'),
      statements.indexOf('revoke all on function public.refresh_admin_review_queue_counts'),
    );
    expect(fn.length).toBeGreaterThan(400);
    expect(occurrences(fn, 'admin_review_finding_codes')).toBe(1);
    expect(fn).toContain('left join public.admin_review_finding_codes f');
    // The rejected shape, in any spelling that reintroduces a correlated subplan.
    expect(fn).not.toMatch(/filter\s*\(\s*where\s+exists/i);
  });

  it('drives FROM admin_review_sources with a LEFT JOIN so an empty source still gets a row', () => {
    // Measured: 20 of 41 active sources hold zero items. A bare `group by
    // queue_type` emits 21 rows, which silently makes "every active source has
    // a cached row" unassertable and the sidebar badge for an empty source
    // indistinguishable from a missing one.
    expect(statements).toContain('from public.admin_review_sources r');
    expect(statements).toContain('left join agg a on a.queue_type = r.queue_key');
    expect(statements).toMatch(/coalesce\(a\.n,0\)/);
  });

  it('takes a TRY advisory lock, not a blocking one', () => {
    // The refresh does the full-corpus scan this migration removes from the
    // request path, and pg_cron does not serialise its own jobs. Blocking would
    // turn a slow run into a queue of pg_cron workers.
    expect(statements).toContain(
      "pg_try_advisory_xact_lock(hashtext('admin_review_queue_counts'))",
    );
    expect(statements).not.toContain('pg_advisory_xact_lock(hashtext');
  });
});

describe('the queue patch is anchored, not restated', () => {
  it('reads the live definition instead of a repo file', () => {
    // Another session rewrote this body hours earlier (99991791920008), and the
    // live prosrc already diverges from the newest repo file through earlier
    // string surgery, so a CREATE OR REPLACE built from any file reverts work.
    expect(statements).toContain('pg_get_functiondef(p.oid)');
    expect(statements).not.toMatch(/create or replace function public\.get_admin_review_queue/i);
    expect(statements).not.toMatch(/create or replace function public\.get_admin_review_summary/i);
  });

  it('requires every anchor to occur exactly once', () => {
    expect(statements).toContain("raise exception 'anchor occurs % times, expected 1: %'");
    expect(statements).toMatch(
      /foreach a_one in array array\[a_mat, ?a_cnt, ?a_scope, ?a_fil, ?a_fmt, ?a_using\]/,
    );
  });

  it('removes the authorized fence and materializes filtered', () => {
    // Both halves, and neither alone is the fix. Un-materializing `authorized`
    // is what lets the scope predicate push into the 41 branches; materializing
    // `filtered` is what stops `(select count(*) from filtered)` re-running the
    // whole union. Without the second, the win collapses 193,574 -> 442,943
    // blocks.
    expect(statements).toContain("replace(v_src, a_mat,   'authorized as (')");
    expect(statements).toContain("replace(v_new, a_fil,   'filtered as materialized (')");
  });

  it('serves the counts from the cache under the SAME role predicate the sources array uses', () => {
    // The old `counts` aggregated the ROLE-FILTERED union, so a moderator's
    // all_total covered only the sources they may read. The cache holds every
    // active source, so dropping this join silently inflates every non-admin's
    // totals -- invisible to an admin, who sees everything.
    expect(statements).toContain(
      'from public.admin_review_queue_counts c join public.admin_review_sources r on r.queue_key=c.queue_key',
    );
    expect(statements).toMatch(/r\.active and \(public\.has_role_jwt\('admin'::public\.app_role\)/);
    expect(statements).toContain(
      "r.min_role='moderator' and public.has_role_jwt('moderator'::public.app_role)",
    );
    expect(statements).toContain(
      "r.min_role='editor' and public.has_any_role_jwt(array['moderator','editor']::public.app_role[])",
    );
  });

  it('folds p_scope to a literal and drops it from the USING list', () => {
    // As a bound parameter the OR-chain cannot be collapsed, so the predicate
    // never reaches the union branches. p_scope is already validated against a
    // five-value whitelist upstream, so there is no injection surface.
    expect(statements).toMatch(/case p_scope when 'all' then 'true'/);
    expect(statements).toContain(
      "'using p_queue_types,p_content_types,v_search,p_sort,v_size,v_page;'",
    );
    expect(statements).toContain(
      "raise exception 'P-patch failed: $4 still occurs % times after folding the scope predicate'",
    );
  });

  it('asserts the placeholder count AND their order', () => {
    // Four %s, and the order decides the argument order because format()
    // forbids mixing %1$s with %s. Getting it wrong is not a syntax error: an
    // earlier draft produced `from (u.overdue) authorized_rows`.
    expect(statements).toMatch(/if v_cnt <> 4 then/);
    expect(statements).toContain("position('details as (%s)' in v_new)");
    expect(statements).toContain("position('coalesce(%s,0) from counts' in v_new)");
  });
});

describe('total comes from the same snapshot as the counters', () => {
  // THE HALF THAT WAS WRONG FIRST. e2e/admin-inbox-renders.spec.ts asserts
  // total === decisions_total, total === all_total and total === overdue_total.
  // Those held because `counts` and `filtered` were two reads of ONE
  // materialized union. Leaving `total` live while the counters are cached
  // makes all three true only by luck, so the obvious caching would have broken
  // the very test this migration exists to fix -- intermittently.
  it('reads the cached scope total on an unfiltered request', () => {
    expect(statements).toContain(
      "'total',case when $1 is null and $2 is null and $3 is null then (select coalesce(%s,0) from counts)",
    );
  });

  it('falls back to the live exact count as soon as any filter is applied', () => {
    // There is no cached equivalent for a queue_type / content_type / search
    // filter, and inventing one would be a wrong number rather than a stale one.
    expect(statements).toContain('else (select count(*) from filtered) end');
  });

  it('maps every one of the five scopes to its own cached aggregate', () => {
    const totalCase = statements.slice(
      statements.indexOf('r_total := '),
      statements.indexOf('v_new := replace(v_src, a_mat'),
    );
    expect(totalCase.length).toBeGreaterThan(80);
    expect(totalCase).toContain("when 'all' then 'sum(n)'");
    expect(totalCase).toContain("when 'decisions' then 'sum(decisions)'");
    expect(totalCase).toContain("when 'overdue' then 'sum(late)'");
    expect(totalCase).toContain("when 'safety' then 'sum(safety)'");
    // public_impact is a per-source CONSTANT in the union, so scope=public needs
    // no column of its own -- it is sum(n) over the public sources.
    expect(totalCase).toContain("else 'sum(n) filter (where public_impact)'");
  });

  it('carries public_impact into the counts CTE so that last arm can resolve', () => {
    expect(statements).toMatch(/c\.safety,r\.public_impact from public\.admin_review_queue_counts/);
  });
});

describe('the summary patch removes the union entirely', () => {
  it('matches its multi-line anchor by regex, not by a literal', () => {
    // The anchor spans ten lines of another session's formatting, and this repo
    // has a standing record of anchors that silently matched nothing over a
    // four-space indent where the source had three.
    expect(statements).toContain(
      "'with authorized as not materialized \\(.*?from authorized group by queue_type\\s*\\)'",
    );
    expect(statements).toContain("select count(*) into v_cnt from regexp_matches(v_src, pat, 'g')");
  });

  it('proves the union is gone rather than merely unreferenced', () => {
    // Postgres would decline to execute an unreferenced non-materialized CTE,
    // but dropping the %s means the 41 branches are never interpolated at all --
    // which is not a planner behaviour this has to trust. format() ignores
    // extra arguments, so the format(...,v_union) call needs no edit.
    expect(statements).toContain(
      "raise exception 'summary still carries % format placeholder(s) after the edit'",
    );
    expect(statements).toContain(
      "raise exception 'summary still reads the authorized CTE after the edit'",
    );
  });
});

describe('the postconditions assert the reached state and not a false premise', () => {
  it('does NOT re-assert that the cron command is run-wrapped', () => {
    // THIS WOULD HAVE ABORTED db push FOR THE WHOLE REPO. Measured before
    // merging, against an existing registered rpc automation and not just
    // against this slug: admin_automation_effective_command() returns an rpc
    // row's command UNCHANGED. Only the two HTTP families get the prefix; this
    // is family C, tracked by admin_automation_project_cron_runs() off
    // cron.job_run_details.
    expect(verify).not.toContain('admin_automation_run_begin');
  });

  it('asserts the live cron command is drift-free instead', () => {
    expect(verify).toContain('j.command = public.admin_automation_effective_command(');
    expect(verify).toContain(
      "raise exception 'P4b failed: the live cron command does not match the reconciler-derived command'",
    );
  });

  it('asserts the two functions agree, which is the check a non-admin needs', () => {
    // Both now derive totals from one cache under one role predicate, so they
    // must match exactly. A role filter dropped from one of the two reads is
    // invisible to an admin and wrong for every moderator.
    expect(verify).toContain("raise exception 'P17 failed: summary and queue totals disagree");
    expect(verify).toContain("if (v_s->'sources') <> (v_q->'sources') then");
  });

  it('EXECUTES both functions, because a plpgsql body is only parsed at CREATE time', () => {
    expect(verify).toContain("public.get_admin_review_queue(p_scope => 'overdue')");
    expect(verify).toContain("public.get_admin_review_queue(p_scope => 'decisions')");
    expect(verify).toContain('public.get_admin_review_summary()');
    expect(verify).toContain("perform set_config('request.jwt.claims'");
  });

  it('counts a positive reached state rather than rows in a bad one', () => {
    // `v_bad = 0` style checks return 0 for a slug that has vanished entirely.
    expect(verify).toMatch(/if v_missing <> 0 then/);
    expect(verify).toMatch(/if v_rows = 0 then/);
    expect(verify).toMatch(/if v_cron <> 1 then/);
  });

  it('does not short-circuit any postcondition', () => {
    expect(verify).not.toMatch(/where false/i);
    expect(verify).not.toMatch(/if \(?false\)? then/i);
  });
});

describe('the cache is unreachable from the client and the index exists', () => {
  it('revokes the table from anon and authenticated and enables RLS', () => {
    expect(statements).toContain(
      'alter table public.admin_review_queue_counts enable row level security',
    );
    expect(statements).toContain(
      'revoke all on table public.admin_review_queue_counts from anon, authenticated',
    );
  });

  it('grants the refresher and the sentinel to service_role only', () => {
    for (const fn of ['refresh_admin_review_queue_counts', 'admin_review_counts_signals']) {
      expect(statements).toContain(`revoke all on function public.${fn}() from public`);
      expect(statements).toContain(`grant execute on function public.${fn}() to service_role`);
      // `to service_role` is a prefix of `to service_role, authenticated`.
      expect(statements).not.toContain(
        `grant execute on function public.${fn}() to service_role, authenticated`,
      );
    }
  });

  it('creates the partial first_seen_at index the pushed-down predicate needs', () => {
    // business-quality's `created_at` is entity_quality_findings.first_seen_at,
    // which no existing index covered, so even a perfectly folded predicate had
    // to seq-scan ~258k rows.
    expect(statements).toContain('create index if not exists admin_review_eqf_first_seen_idx');
    expect(statements).toContain('on public.entity_quality_findings (first_seen_at)');
    expect(statements).toMatch(
      /where state = any \(array\['fail'::text, 'pending'::text\]\) and waived_at is null/,
    );
  });

  it('registers the cron in the registry AND schedules it in the same migration', () => {
    // An action->>'type'='rpc' row is not reachable by sync_automations_to_cron
    // branch (d) on its own.
    expect(statements).toContain('insert into public.admin_automations');
    expect(statements).toContain("'jobname','admin_review_counts_refresh'");
    expect(statements).toContain("cron.schedule('admin_review_counts_refresh', '*/2 * * * *'");
    expect(statements).toContain("cron.unschedule('admin_review_counts_refresh')");
    // Seeded at apply time so the cache is never empty: an empty cache reports
    // every total as 0, which on a ~327k backlog is a confident lie.
    expect(statements).toContain('select public.refresh_admin_review_queue_counts();');
  });
});

describe('the sentinel is wired into the health script before its terminal exit', () => {
  const health = readFileSync(HEALTH, 'utf8');

  it('calls the RPC over the REST endpoint', () => {
    // Anchored on the fetch, not on the function name: a name in a comment
    // satisfies a bare toContain while nothing calls it.
    expect(health).toContain('/rest/v1/rpc/admin_review_counts_signals');
  });

  it('runs BEFORE the terminal process.exit(1), not after it', () => {
    // A section appended after the exit prints its failure and still exits 0.
    // lastIndexOf, because this script has an early env-guard exit too.
    expect(health.indexOf('admin_review_counts_signals')).toBeLessThan(
      health.lastIndexOf('process.exit(1)'),
    );
  });

  it('reports the denominators before the invariant', () => {
    const idxDenom = health.indexOf('review counts cache: ');
    const idxInvariant = health.indexOf('have no cached counts row');
    expect(idxDenom).toBeGreaterThan(-1);
    expect(idxInvariant).toBeGreaterThan(idxDenom);
  });

  it('hard-fails on a broken probe and on zero denominators', () => {
    const section = health.slice(health.indexOf('/rest/v1/rpc/admin_review_counts_signals'));
    expect(section).toContain('probe_ok is not true');
    expect(section).toContain('reports 0 active sources');
    expect(section).toContain('the review counts cache is EMPTY');
  });

  it('warns rather than fails on the undeployed window', () => {
    const section = health.slice(health.indexOf('/rest/v1/rpc/admin_review_counts_signals'));
    expect(section).toMatch(/if \(res\.status === 404\)[\s\S]{0,320}console\.warn/);
  });

  it('gates staleness on AGE and not on a level', () => {
    const section = health.slice(health.indexOf('/rest/v1/rpc/admin_review_counts_signals'));
    expect(section).toContain('oldest_age_seconds');
    expect(section).toMatch(/age > 3600/);
  });
});
