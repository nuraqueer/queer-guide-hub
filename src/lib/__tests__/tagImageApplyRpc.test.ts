/**
 * Guards 99991791724090_tag_image_apply_rpc.sql and the two call sites it exists
 * for.
 *
 * Running tag-imagery ONCE found three defects no test, typecheck or green
 * deploy had caught, because the function had never executed:
 *
 *   1. verify_jwt defaulted on, so the gateway 401'd the only caller.
 *   2. `unified_tags.enrichment_status` did not exist.
 *   3. A plain PostgREST update cannot write a `human_reviewed` tag --
 *      `log_unified_tag_change()` RAISEs for an undeclared `system:%` actor,
 *      and 79% of prose-bearing active tags carry that flag.
 *
 * These assertions are what stop (2) and (3) coming back. Both sources are read
 * COMMENT-STRIPPED: the migration header and the function's own comments quote
 * every defect being asserted away, so an unstripped `toContain` would match the
 * prose while the statement was gone -- the vacuous-assertion class CLAUDE.md
 * records repeatedly.
 */
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = join(__dirname, '../../..');
const MIGRATION = '99991791724090_tag_image_apply_rpc.sql';

const rawSql = readFileSync(join(ROOT, 'supabase/migrations', MIGRATION), 'utf8');
const rawFn = readFileSync(join(ROOT, 'supabase/functions/tag-imagery/index.ts'), 'utf8');

/** Drop `--` comments that START a line. A mid-line `--` can sit inside a string. */
const stripSql = (s: string) =>
  s
    .split('\n')
    .filter((l) => !l.trimStart().startsWith('--'))
    .join('\n');

/** Drop `//` line comments and `/* *\/` blocks from TypeScript. */
const stripTs = (s: string) =>
  s
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')
    .filter((l) => !l.trimStart().startsWith('//'))
    .join('\n');

const sql = stripSql(rawSql);
const fn = stripTs(rawFn);

/** Statements only -- the verify block echoes the strings the statements carry. */
const verifyStart = sql.indexOf('do $verify$');
const statements = sql.slice(0, verifyStart);
const verify = sql.slice(verifyStart);

describe('tag_image_apply_rpc migration', () => {
  it('is split at the verify block, so scoped assertions are not vacuous', () => {
    expect(verifyStart).toBeGreaterThan(0);
    expect(statements.length).toBeGreaterThan(1000);
    expect(verify.length).toBeGreaterThan(1000);
  });

  it('adds enrichment_status as jsonb', () => {
    expect(statements).toMatch(
      /alter table public\.unified_tags\s+add column if not exists enrichment_status jsonb/,
    );
  });

  it('PATCHES log_unified_tag_change from pg_get_functiondef rather than restating it', () => {
    // Restating is how one session silently reverts another's narrowing
    // (99991790719601). The patch must read the LIVE definition.
    expect(statements).toContain('pg_get_functiondef(p.oid)');
    expect(statements).toContain("p.proname = 'log_unified_tag_change'");
    // A restatement would have to declare the function.
    expect(statements).not.toMatch(/create or replace function public\.log_unified_tag_change/i);
  });

  it('asserts its anchor appears EXACTLY once before patching', () => {
    // A body that has moved must fail loudly rather than be half-patched.
    expect(statements).toMatch(/v_hits\s*<>\s*1/);
    expect(statements).toMatch(/raise exception[\s\S]{0,200}expected exactly 1/);
  });

  it('no-ops when the exemption is already present, testing STRIPPED source', () => {
    // Re-run, or another session got there first.
    //
    // The idempotency check must read a comment-stripped copy, while `v_src`
    // itself stays raw because the patch re-executes the real definition
    // including its comments. Unstripped, a comment that merely NAMES the
    // column -- which part 2 of this file adds to the function -- reads as
    // "already patched", the patch skips, and P2 (which strips) then aborts
    // `db push` for every migration queued behind it.
    expect(statements).toMatch(
      /position\('''enrichment_status'''\s+in\s+regexp_replace\(v_src,[\s\S]{0,80}?\)\)\s*>\s*0/,
    );
    // ...and the raw definition is still what gets re-executed.
    expect(statements).toMatch(/execute replace\(v_src, v_from, v_to\)/);
  });

  for (const proc of ['tag_image_apply', 'tag_image_bump_miss']) {
    describe(proc, () => {
      const body = (() => {
        const start = statements.indexOf(`create or replace function public.${proc}(`);
        expect(start).toBeGreaterThan(0);
        const end = statements.indexOf('$fn$;', start);
        expect(end).toBeGreaterThan(start);
        return statements.slice(start, end);
      })();

      it('is SECURITY DEFINER with a pinned search_path', () => {
        expect(body).toContain('security definer');
        expect(body).toMatch(/set search_path to 'public'/);
      });

      it('declares the actor, which is the entire reason it is definer', () => {
        expect(body).toContain("set_config('app.actor', 'machine:tag-imagery', true)");
      });

      it('raises 22023 on an unknown tag rather than silently writing nothing', () => {
        expect(body).toMatch(/raise exception 'tag % not found', p_tag_id using errcode = '22023'/);
      });

      it('is revoked from public, anon and authenticated and granted to service_role', () => {
        // CREATE FUNCTION grants EXECUTE to PUBLIC, so the REVOKE is the
        // load-bearing statement; the grant alone changes nothing.
        for (const role of ['public', 'anon', 'authenticated']) {
          expect(statements).toMatch(
            new RegExp(`revoke all on function public\\.${proc}\\([^)]*\\) from ${role};`),
          );
        }
        // `to service_role` is a PREFIX of `to service_role, authenticated` --
        // the exact leak this asserts against -- so the match is terminated.
        expect(statements).toMatch(
          new RegExp(`grant execute on function public\\.${proc}\\([^)]*\\) to service_role;`),
        );
      });

      it('does not disable or bypass the contract trigger', () => {
        expect(body).not.toMatch(/disable trigger/i);
        expect(body).not.toMatch(/session_replication_role/i);
      });
    });
  }

  it('tag_image_apply writes all six image columns', () => {
    const start = statements.indexOf('create or replace function public.tag_image_apply(');
    const body = statements.slice(start, statements.indexOf('$fn$;', start));
    for (const col of [
      'image_url',
      'image_alt',
      'image_source',
      'image_license',
      'image_attribution',
      'image_explicit',
    ]) {
      expect(body).toMatch(new RegExp(`${col}\\s*=\\s*`));
    }
  });

  it('tag_image_apply CLEARS the attempt state on success', () => {
    // A tag that resolved on attempt 3 must not keep a terminal stamp -- that
    // is a record of a question since answered.
    const start = statements.indexOf('create or replace function public.tag_image_apply(');
    const body = statements.slice(start, statements.indexOf('$fn$;', start));
    expect(body).toMatch(/enrichment_status\s*=\s*v_status\s*-\s*'tag_image'/);
  });

  it('tag_image_apply claims the asset link only when given one', () => {
    const start = statements.indexOf('create or replace function public.tag_image_apply(');
    const body = statements.slice(start, statements.indexOf('$fn$;', start));
    expect(body).toMatch(/if p_asset_id is not null then/);
    expect(body).toContain('insert into public.image_asset_links');
    expect(body).toMatch(/'tag'[\s\S]{0,40}'cover'/);
  });

  it('tag_image_bump_miss increments SERVER-SIDE, never from a parameter', () => {
    const start = statements.indexOf('create or replace function public.tag_image_bump_miss(');
    const body = statements.slice(start, statements.indexOf('$fn$;', start));
    // The count comes off the row, so two concurrent batches cannot lose one.
    expect(body).toMatch(
      /v_attempts\s*:=\s*coalesce\(\(v_status\s*#>>\s*'\{tag_image,attempts\}'\)::int,\s*0\)\s*\+\s*1/,
    );
    // An attempts parameter would reintroduce the read-modify-write.
    expect(body).not.toMatch(/p_attempts/);
  });

  it('tag_image_bump_miss makes three strikes terminal', () => {
    const start = statements.indexOf('create or replace function public.tag_image_bump_miss(');
    const body = statements.slice(start, statements.indexOf('$fn$;', start));
    expect(body).toMatch(/v_attempts\s*>=\s*3\s+then\s+'data_unavailable'/);
    expect(body).toContain("else 'searching'");
  });
});

describe('tag_image_apply_rpc postconditions', () => {
  it('P2 strips comments before searching the definition', () => {
    // Found by mutation: reverting P2 to a bare `pg_get_functiondef(p.oid)`
    // SURVIVED, because nothing here asserted the strip. `pg_get_functiondef()`
    // returns the body INCLUDING comments, and part 2 of this migration adds a
    // comment to `log_unified_tag_change` that NAMES `enrichment_status` -- so
    // the unstripped form is satisfied by the prose and passes with the array
    // entry missing. Falsely GREEN, which is the worse direction.
    //
    // `scripts/check-functiondef-asserts.mjs` is the CI gate for this class and
    // it caught the original on PR #4303; this is the repo-local half, so the
    // property is guarded where it is cheap to see rather than only at apply.
    const p2 = verify.slice(verify.indexOf('into v_src'), verify.indexOf('P2 failed'));
    expect(p2.length).toBeGreaterThan(0);
    expect(verify).toMatch(
      /regexp_replace\(pg_get_functiondef\(p\.oid\),\s*'--\[\^'\s*\|\|\s*chr\(10\)\s*\|\|\s*'\]\*'/,
    );
    // chr(10), never a '\n' literal: in a plain single-quoted PostgreSQL string
    // a backslash-n is two characters, so the pattern would match neither.
    expect(verify).not.toMatch(/regexp_replace\(pg_get_functiondef\([^)]*\),\s*'--\[\^\\n\]/);
  });

  it('counts the postcondition CONDITIONS, not just the messages they print', () => {
    // Found by mutation: neutering P10's `if v_bad <> 0` to `if v_bad < 0`
    // SURVIVED. Every string-anchored assertion stayed green -- the slug list,
    // the regex and the `P10 failed` text are all untouched -- while the check
    // had stopped checking. Anchoring on the condition is the documented fix
    // (60000101160000), and a count is what makes it hold for all of them.
    const conds = verify.match(/if\s+v_bad\s*<>\s*0\s+then/g) ?? [];
    expect(conds.length).toBeGreaterThanOrEqual(2);
    // No loosened comparison anywhere in the block.
    expect(verify).not.toMatch(/if\s+v_bad\s*[<>]\s*0\s+then/);
    expect(verify).not.toMatch(/v_bad\s*(<=|>=)\s*0/);
  });

  it('asserts the column, the exemption and BOTH pre-existing exemptions', () => {
    // A patch that REPLACED the array rather than extending it satisfies the
    // enrichment_status check alone.
    expect(verify).toMatch(/P1 failed/);
    expect(verify).toMatch(/P2 failed/);
    expect(verify).toContain("'''prose_reviewed_at'''");
    expect(verify).toContain("'''usage_count'''");
  });

  it('asserts both RPCs are definer and service_role-only', () => {
    expect(verify).toContain('p.prosecdef is not true');
    expect(verify).toContain("has_function_privilege('anon', p.oid, 'EXECUTE')");
    expect(verify).toContain("has_function_privilege('authenticated', p.oid, 'EXECUTE')");
    expect(verify).toContain("not has_function_privilege('service_role', p.oid, 'EXECUTE')");
  });

  it('proves a human_reviewed row CAN be stamped through the RPC', () => {
    // The whole point, and the PROBE's own flag is what makes P4 and P5 mean
    // anything: insert it `human_reviewed = false` and P4 passes while proving
    // nothing about the actor declaration. Assert the probe shape, not just
    // that the word appears somewhere in the block.
    expect(verify).toMatch(
      /insert into public\.unified_tags \([^)]*human_reviewed\)[\s\S]{0,200}'utility', true\)/,
    );
    expect(verify).toMatch(/P4 failed/);
    expect(verify).toContain('tag_image_bump_miss(v_probe');
  });

  it('proves the UNDECLARED path is still refused, using the real publish shape', () => {
    // An `image_alt`-only probe FAILED against correct code:
    // zz_enforce_tag_image_contract clears the sidecar when image_url is null,
    // so NEW == OLD, nothing changed, and the AFTER trigger was right not to
    // fire. A self-reverting write is indistinguishable from a dead guard.
    expect(verify).toMatch(/P5 failed/);
    expect(verify).toContain("set_config('app.actor', 'system:trigger', true)");
    const p5 = verify.slice(verify.indexOf("'system:trigger'"), verify.indexOf('P5 failed'));
    for (const col of [
      'image_url',
      'image_alt',
      'image_source',
      'image_license',
      'image_attribution',
      'image_explicit',
    ]) {
      expect(p5).toContain(col);
    }
  });

  it('asserts the RPC does NOT bypass enforce_tag_image_contract', () => {
    // An unlicensed publish through the RPC must still raise check_violation.
    expect(verify).toMatch(/P7 failed/);
    expect(verify).toContain('exception when check_violation then');
  });

  it('asserts a well-formed publish lands AND clears state', () => {
    expect(verify).toMatch(/P8 failed/);
    expect(verify).toMatch(/if v_state is not null then/);
  });

  it('leaves no probe row behind', () => {
    expect(verify).toContain('delete from public.unified_tags where id = v_probe');
    expect(verify).toMatch(/P9 failed/);
    expect(verify).toMatch(/slug like 'zz-tag-image-rpc-probe%'/);
  });

  it('counts every postcondition, so a loosened comparison cannot hide', () => {
    // Neutering `if v_bad <> 0` to `if v_bad < 0` leaves every string-anchored
    // assertion green while the check has stopped checking (60000101160000).
    //
    // `P1 failed` is NOT a prefix of `P10 failed` -- after `P1` comes `0`, not a
    // space -- so a plain substring check per n cannot be satisfied by the
    // wrong postcondition. Checked rather than assumed, because the shared-
    // prefix trap (`to service_role` inside `to service_role, authenticated`)
    // is one this repo has been bitten by.
    for (let n = 1; n <= 10; n++) {
      expect(verify).toContain(`P${n} failed`);
    }
    expect(verify).not.toMatch(/\bwhere false\b/);
    expect(verify).not.toMatch(/if\s+false\s+then/);
  });
});

describe('the superseded provenance automation', () => {
  /**
   * Scoped to the ONE statement, because `description` and the slug both appear
   * in P10's query too -- an assertion over the whole statements region would
   * match there and pass with this UPDATE deleted.
   *
   * Computed LAZILY, and the end is the statement's own terminating semicolon
   * rather than an offset from the idempotency guard's literal. A first draft
   * did both the other way and mutation testing reported HARNESS-BROKEN rather
   * than a catch: removing the guard made the inner `indexOf` return -1, the
   * slice collapsed, and an `expect()` evaluated at describe time threw during
   * COLLECTION, so vitest ran no tests at all. "No tests" is not a failure a
   * careless harness distinguishes from a pass -- so the anchor must not depend
   * on the thing being mutated, and nothing may assert at module scope.
   * None of the SET clause's string literals contains a semicolon, checked.
   */
  const stmt = () => {
    const start = statements.indexOf('update public.admin_automations');
    const end = statements.indexOf(';', start);
    return start < 0 || end < 0 ? '' : statements.slice(start, end);
  };

  it('PREPENDS, preserving the previous description verbatim', () => {
    // A first draft retyped the whole description from what the row said when
    // the file was authored. By merge time a concurrent session had added
    // `[COMPLETED 2026-09-26: verified no eligible work remains]`, so retyping
    // would have discarded another session's measurement -- and the retyped
    // "original note" had merged two of the retirement note's sentences into
    // one while presenting itself as a quote. `|| description` cannot do either.
    expect(stmt()).toMatch(/\|\|\s*description\s*$/m);
    expect(stmt()).toContain('[SUPERSEDED 2026-10-11');
  });

  it('does not write `enabled`, so the reconciler still cannot re-arm it', () => {
    // Re-enabling a retired automation as a side effect of a feature is the
    // Wolfram-cron / detect_stale_venues shape. `sync_automations_to_cron()`
    // branch (b) is a kill switch only while `enabled` stays false.
    //
    // Scoped to the SET clause. A first draft used `/set[\s\S]*\benabled\b=/`
    // over the whole statement and FAILED on correct code, because the greedy
    // span reached the WHERE clause's own `enabled = false` -- an anchor wider
    // than the claim. That direction is the cheap one; the same width in a
    // negative assertion passes while the thing it guards is gone.
    const s = stmt();
    const setClause = s.slice(0, s.indexOf(' where '));
    expect(setClause.length).toBeGreaterThan(0);
    expect(setClause).not.toMatch(/\benabled\b/);
    expect(s.slice(s.indexOf(' where '))).toMatch(/enabled\s*=\s*false/);
  });

  it('is idempotent, so a replay cannot stack the note onto itself', () => {
    expect(stmt()).toMatch(/description not like '\[SUPERSEDED%'/);
  });

  it('P10 asserts BOTH halves, and asserts the REACHED state', () => {
    // `enabled = false` alone passes while the row still tells the next reader
    // that image_url is null corpus-wide; the text alone passes if this
    // migration re-armed a retired automation. The text half is POSITIVE
    // (`not like '[SUPERSEDED%'`) rather than an absence check on the old
    // phrase, because the replacement QUOTES the false claim in order to
    // explain it -- an absence pattern would have to miss its own quotation.
    const p10 = verify.slice(
      verify.indexOf("slug = 'tag_image_provenance_sync'"),
      verify.indexOf('P10 failed'),
    );
    expect(p10.length).toBeGreaterThan(0);
    expect(p10).toMatch(/enabled/);
    expect(p10).toMatch(/description not like '\[SUPERSEDED%'/);
  });
});

describe('tag-imagery call sites', () => {
  it('publishes through the RPC, never a PostgREST update', () => {
    expect(fn).toContain("supabase.rpc('tag_image_apply'");
    expect(fn).not.toMatch(/from\('unified_tags'\)\s*\.?\s*\n?\s*\.update\(/);
    expect(fn).not.toMatch(/\.from\('unified_tags'\)[\s\S]{0,80}\.update\(/);
  });

  it('passes all six image values plus the asset id to the RPC', () => {
    const start = fn.indexOf("supabase.rpc('tag_image_apply'");
    const call = fn.slice(start, fn.indexOf('})', start));
    for (const p of [
      'p_tag_id',
      'p_url',
      'p_alt',
      'p_source',
      'p_license',
      'p_attribution',
      'p_explicit',
      'p_asset_id',
    ]) {
      expect(call).toContain(p);
    }
  });

  it('records a miss through the RPC and sends no attempt count', () => {
    expect(fn).toContain("supabase.rpc('tag_image_bump_miss'");
    const start = fn.indexOf("supabase.rpc('tag_image_bump_miss'");
    const call = fn.slice(start, fn.indexOf('})', start));
    expect(call).toContain('p_tag_id');
    expect(call).toContain('p_why');
    expect(call).not.toContain('p_attempts');
  });

  it('still skips the miss stamp on a dry run', () => {
    const start = fn.indexOf('async function bumpMiss');
    const body = fn.slice(start, start + 1200);
    expect(body).toMatch(/if \(dryRun\) return/);
  });

  it('registerAsset no longer claims the cover link', () => {
    // The link must be claimed in the same transaction as the six columns, or a
    // contract refusal leaves an orphan cover link holding the asset hostage.
    const start = fn.indexOf('async function registerAsset');
    const body = fn.slice(start, fn.indexOf('\n}', fn.indexOf('return data.id as string', start)));
    expect(body).not.toContain('image_asset_links');
    expect(body).not.toMatch(/link:\s*\{\s*tagId/);
  });

  it('keeps the terminal sentinel reading enrichment_status in the selector', () => {
    // The column is what removes an unresolvable tag from the pool; a selector
    // that stopped reading it would re-probe the same rows forever.
    expect(fn).toContain('enrichment_status');
    expect(fn).toMatch(/tag_image\?\.state\s*!==/);
  });
});

describe('tag-imagery is reachable by its only caller', () => {
  const config = readFileSync(join(ROOT, 'supabase/config.toml'), 'utf8');

  it('sets verify_jwt = false, or the gateway 401s the pg_net driver', () => {
    // The driver posts with ONLY x-internal-secret and no Authorization header,
    // so with verify_jwt on the platform answers UNAUTHORIZED_NO_AUTH_HEADER
    // before requireInternalOrAdmin ever runs. Measured, not inferred.
    const idx = config.indexOf('[functions.tag-imagery]');
    expect(idx).toBeGreaterThan(0);
    // The next section may not exist (this entry can be last), and indexOf's -1
    // would silently chop the final character off the slice.
    const nextIdx = config.indexOf('[functions.', idx + 10);
    const section = config.slice(idx, nextIdx === -1 ? undefined : nextIdx);

    // Assert the key is declared EXACTLY ONCE and that the one declaration is
    // false. A bare /^verify_jwt = false$/m is satisfied by a section that
    // declares BOTH values -- mutation-tested: inserting `verify_jwt = true`
    // above the real line left that assertion green while the section now
    // declares the gateway check ON.
    const declarations = section.match(/^verify_jwt = \w+$/gm) ?? [];
    expect(declarations).toEqual(['verify_jwt = false']);
  });

  it('self-gates in the function, so verify_jwt = false is not the only check', () => {
    expect(fn).toMatch(/requireInternalOrAdmin/);
  });
});
