import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Guards 99991791954004_news_source_items_seen_counters.
 *
 * `news_sources.articles_fetched` and `avg_articles_per_fetch` had a single
 * writer, `news_source_record_outcome`, which has had no caller for as long as
 * the current ingest path has existed -- so 376 of 397 sources read 0 while the
 * feeds were healthy, and `avg_articles_per_fetch` rendered 0.00 at
 * /admin/pipelines?tab=news. This asserts the replacement writer exists, keeps
 * the ORIGINAL items-seen semantics, and is wired into both completion legs of
 * source-rss-news.
 *
 * Every assertion runs over COMMENT-STRIPPED source. The migration header and
 * the edge-function comments quote the old formula, the defect and the
 * quantities being asserted, so a `toContain` over raw text passes with the
 * executable line deleted.
 */

const MIGRATION = '99991791954004_news_source_items_seen_counters.sql';
const RPC = 'news_source_record_items_seen';

const stripSqlComments = (sql: string) =>
  sql
    .split('\n')
    .filter((line) => !line.trimStart().startsWith('--'))
    .map((line) => line.replace(/--.*$/, ''))
    .join('\n');

const stripTsComments = (ts: string) =>
  ts
    .split('\n')
    .filter((line) => !line.trimStart().startsWith('//'))
    .join('\n');

const migrationRaw = readFileSync(join(process.cwd(), 'supabase/migrations', MIGRATION), 'utf8');
const sql = stripSqlComments(migrationRaw);

const fnRaw = readFileSync(
  join(process.cwd(), 'supabase/functions/source-rss-news/index.ts'),
  'utf8',
);
const fn = stripTsComments(fnRaw);

// The function body: from CREATE to the terminating $fn$;
const fnBody = sql.slice(
  sql.indexOf(`create or replace function public.${RPC}`),
  sql.indexOf('$fn$;') + '$fn$;'.length,
);
// The verify block, so assertions about postconditions cannot match the body.
const verify = sql.slice(sql.indexOf('do $verify$'));
// Just the UPDATE's SET list, so "touches nothing else" is about the right half.
const setList = fnBody.slice(fnBody.indexOf('set '), fnBody.indexOf('where id = p_source_id'));

describe('the comment strippers are not vacuous', () => {
  it('removes commentary while keeping statements', () => {
    // Positive control: without this the whole file is satisfiable by prose.
    expect(migrationRaw).toContain('-- SEMANTICS ARE THE OLD ONES');
    expect(sql).not.toContain('SEMANTICS ARE THE OLD ONES');
    expect(sql).toContain(`create or replace function public.${RPC}`);

    expect(fnRaw).toContain('// articles_fetched / avg_articles_per_fetch, in the ORIGINAL sense');
    expect(fn).not.toContain('in the ORIGINAL sense');
    expect(fn).toContain(`supabase.rpc('${RPC}'`);
  });

  it('found a non-trivial slice for each region it asserts on', () => {
    // An empty slice makes every assertion scoped to it pass. Recorded trap:
    // indexOf on a label that is comment-only yields an EMPTY span.
    expect(fnBody.length).toBeGreaterThan(200);
    expect(verify.length).toBeGreaterThan(500);
    expect(setList.length).toBeGreaterThan(80);
    expect(verify.indexOf('do $verify$')).toBe(0);
  });
});

describe('the counter writer keeps the original items-seen semantics', () => {
  it('accumulates rather than replacing', () => {
    expect(fnBody).toMatch(
      /articles_fetched\s*=\s*coalesce\(articles_fetched,\s*0\)\s*\+\s*greatest\(0,\s*coalesce\(p_items_seen,\s*0\)\)/,
    );
  });

  it('keeps the old EWMA weights byte-for-byte', () => {
    expect(fnBody).toMatch(
      /avg_articles_per_fetch\s*=\s*\(coalesce\(avg_articles_per_fetch,\s*0\)\s*\*\s*0\.8\)/,
    );
    expect(fnBody).toMatch(/\*\s*0\.2\)/);
  });

  it('clamps a negative or null count so a total can never decrement', () => {
    // greatest(0, coalesce(...)) must guard BOTH columns, not just the total.
    const clamps = fnBody.match(/greatest\(0,\s*coalesce\(p_items_seen,\s*0\)\)/g) ?? [];
    expect(clamps).toHaveLength(2);
  });

  it('writes exactly the two counter columns and nothing else', () => {
    expect(setList).toContain('articles_fetched');
    expect(setList).toContain('avg_articles_per_fetch');
    // reliability_score feeds news_sources_eligible's wait multiplier; status,
    // last_error and backoff_until are owned by the fetch path. Moving any of
    // them here would change which feeds are eligible when.
    for (const forbidden of [
      'reliability_score',
      'status',
      'last_error',
      'backoff_until',
      'last_successful_fetch',
      'consecutive_failures',
      'consecutive_empty_fetches',
      'auto_paused',
      'updated_at',
    ]) {
      expect(setList).not.toContain(forbidden);
    }
  });

  it('does not adopt the uncalled news_source_record_outcome', () => {
    expect(sql).not.toContain('news_source_record_outcome');
  });
});

describe('the RPC is not reachable by untrusted roles', () => {
  it('is SECURITY INVOKER', () => {
    expect(fnBody).toContain('security invoker');
    expect(fnBody).not.toContain('security definer');
  });

  it('revokes from public and grants only service_role', () => {
    expect(sql).toMatch(
      new RegExp(`revoke all on function public\\.${RPC}\\(uuid, integer\\) from public`),
    );
    expect(sql).toMatch(
      new RegExp(`grant execute on function public\\.${RPC}\\(uuid, integer\\) to service_role`),
    );
    // `to service_role` also matches `to service_role, authenticated` -- the
    // leak this exists to refuse (recorded trap), so ban the roles by name.
    const grants = sql.match(/grant execute on function[^;]*;/g) ?? [];
    expect(grants).toHaveLength(1);
    // Scope the role ban to the GRANTEE half: `public` is also the schema name
    // in `public.news_source_record_items_seen`, so a whole-statement ban fails
    // on correct code (an anchor wider than the claim).
    const grant = grants[0] ?? '';
    expect(grant).not.toHaveLength(0);
    const grantees = grant.slice(grant.lastIndexOf(' to ') + 4);
    expect(grantees).toContain('service_role');
    expect(grantees).not.toContain('anon');
    expect(grantees).not.toContain('authenticated');
    expect(grantees).not.toMatch(/\bpublic\b/);
  });
});

describe('the postconditions assert behaviour, and each one raises', () => {
  it('checks the security mode, the grants and the rollback', () => {
    expect(verify).toContain('prosecdef = false');
    expect(verify).toContain("has_function_privilege('anon'");
    expect(verify).toContain("has_function_privilege('authenticated'");
    expect(verify).toContain("has_function_privilege('service_role'");
  });

  it('actually CALLS the function rather than asserting its source text', () => {
    // A source-text postcondition cannot tell a live function from a dead one,
    // which is the defect being repaired.
    expect(verify).toMatch(new RegExp(`perform public\\.${RPC}\\(v_id, 7\\)`));
    expect(verify).toMatch(new RegExp(`perform public\\.${RPC}\\(v_id, -5\\)`));
    expect(verify).toContain('v_before_cnt + 7');
  });

  it('probes inside a subtransaction that rolls itself back', () => {
    expect(verify).toContain("raise exception 'rollback_counter_probe'");
    expect(verify).toContain("if sqlerrm <> 'rollback_counter_probe' then");
    // The handler must re-raise anything else, or a failed assertion is eaten
    // and the migration reports success.
    expect(verify).toMatch(/if sqlerrm <> 'rollback_counter_probe' then\s*\n\s*raise;/);
  });

  it('raises on every numbered postcondition, not merely mentions it', () => {
    // Replacing a `raise exception` with `null;` leaves every string-anchored
    // check green while the postcondition has stopped failing (recorded trap).
    // Each DISTINCT message, not a shared prefix: 'P3 failed' opens three
    // separate raises, so a prefix match passes with any one of them gutted
    // (recorded trap). A loose `>=` bound tolerates it for the same reason,
    // so the total is exact.
    for (const message of [
      'P1 failed: news_source_record_items_seen missing or SECURITY DEFINER',
      'P2 failed: anon or authenticated can execute the counter RPC',
      'P2 failed: service_role cannot execute the counter RPC',
      'P3 failed: no news_sources row to probe (cannot verify behaviour)',
      'P3 failed: articles_fetched % -> %, expected %',
      'P3 failed: avg_articles_per_fetch % -> %, expected %',
      'P4 failed: a negative count moved articles_fetched to %',
      'P5 failed: probe was not rolled back (% / %)',
    ]) {
      expect(verify).toContain(`raise exception '${message}`);
    }
    const raises = verify.match(/raise exception '/g) ?? [];
    // The 8 above plus the deliberate rollback probe. Exact, so gutting one
    // cannot hide inside the bound.
    expect(raises).toHaveLength(9);
  });

  it('refuses to pass when there is no row to probe', () => {
    // "zero rows behaved correctly" is equally true of an empty table.
    expect(verify).toContain('cannot verify behaviour');
  });
});

describe('source-rss-news records items seen on both completion legs', () => {
  it('calls the RPC with the branch-deciding quantity', () => {
    expect(fn).toMatch(
      new RegExp(`supabase\\.rpc\\('${RPC}',\\s*\\{[^}]*p_items_seen:\\s*articles\\.length`),
    );
    // allItems is capped by RUN_ITEM_BUDGET and sliced by maxArticles, so it is
    // NOT what this fetch saw.
    expect(fn).not.toMatch(
      new RegExp(`supabase\\.rpc\\('${RPC}',\\s*\\{[^}]*p_items_seen:\\s*allItems`),
    );
  });

  it('sits after BOTH legs, so an empty fetch is recorded too', () => {
    const emptyLeg = fn.indexOf("last_error: 'fetched 0 items (silent zero)'");
    const successLeg = fn.indexOf("update(ok).eq('id', source.id)");
    const call = fn.indexOf(`supabase.rpc('${RPC}'`);
    const catchLeg = fn.indexOf('} catch (e) {');
    expect(emptyLeg).toBeGreaterThan(0);
    expect(successLeg).toBeGreaterThan(0);
    expect(call).toBeGreaterThan(emptyLeg);
    expect(call).toBeGreaterThan(successLeg);
    // Still inside the try, so a thrown fetch records nothing -- a failed fetch
    // saw no items and the old writer wrote nothing on failure.
    expect(call).toBeLessThan(catchLeg);
  });

  it('counts and reports a counter-write failure instead of swallowing it', () => {
    expect(fn).toContain('counterErrors++');
    expect(fn).toMatch(/let counterErrors = 0/);
    expect(fn).toMatch(/if \(counterErrors > 0\)/);
    // A bare `.then(() => {}, () => {})` made a write failure, a constraint
    // violation and a success the same silence (recorded trap).
    expect(fn).toMatch(/const \{ error: counterError \} = await supabase\.rpc/);
    expect(fn).toMatch(/if \(counterError\) \{/);
  });

  it('does not abort the source on a counter failure', () => {
    // The fetch is the deliverable; bookkeeping must not discard it. The
    // failure leg must not throw or `continue`.
    const start = fn.indexOf('if (counterError) {');
    const block = fn.slice(start, start + 320);
    expect(block.length).toBeGreaterThan(50);
    expect(block).not.toContain('throw');
    expect(block).not.toContain('continue');
  });
});
