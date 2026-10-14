import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

/**
 * organizations fed 69% of a 99,985-row search_reindex_queue (2026-10-14), and
 * two independent defects produced it:
 *
 *   1. completeness_score had TWO writers with different formulas
 *      (run_org_quality_recompute, 9-field weighted, needs_attention < 40;
 *      refresh_business_brand_quality, dimension pass-rate, < 60). Measured
 *      over 3,000 rows they disagreed on 3,000 of 3,000, so each overwrote the
 *      other forever — 85,598 rows in one statement at 02:50, then 2,000 every
 *      15 minutes.
 *   2. trg_search_documents_organization was unscoped, so any write at all
 *      enqueued a reindex — and 95.3% of the queued organizations are
 *      venue-generated identities the indexer is written to EXCLUDE, costing
 *      98 ms each to produce nothing.
 *
 * 99991791966717 gives the column one writer; 99991791966722 makes the trigger
 * compare values. NEITHER IS WORTH MUCH ALONE: refresh must keep stamping
 * quality_checked_at unconditionally (it is its round-robin cursor), and only
 * the value-scoped trigger makes those 192,000 writes/day free.
 *
 * Text check against the migrations directory so it runs in CI without
 * credentials — same pattern as orgNeedsAttentionRule.test.ts.
 */

const MIGRATIONS = join(process.cwd(), 'supabase', 'migrations');

function read(file: string): string {
  return readFileSync(join(MIGRATIONS, file), 'utf8');
}

/**
 * Strip `--` line comments. BOTH migrations quote the defect verbatim in their
 * headers — the old UPDATE, the column names, "unscoped" — so an unstripped
 * `toContain` is satisfied by the prose while the statement is gone. This is
 * the single most repeated trap in this repo's guard tests.
 */
function statementsOnly(sql: string): string {
  return sql
    .split('\n')
    .map((line) => line.replace(/--.*$/, ''))
    .join('\n');
}

const WRITER = '99991791966717_org_quality_single_writer_completeness.sql';
const TRIGGER = '99991791966722_org_search_trigger_value_scoped.sql';

const writerRaw = read(WRITER);
const triggerRaw = read(TRIGGER);
const writer = statementsOnly(writerRaw);
const trigger = statementsOnly(triggerRaw);

/** The comment stripper must actually be doing something, or every negative
 *  assertion below is vacuous. */
it('the comment stripper is load-bearing', () => {
  expect(writerRaw.length).toBeGreaterThan(writer.length + 500);
  expect(triggerRaw.length).toBeGreaterThan(trigger.length + 500);
});

describe('99991791966717 — one writer for organizations.completeness_score', () => {
  it('patches the live definition instead of restating a 200-line function', () => {
    // Restating it from a repo file silently reverts whatever another session
    // last string-patched into the live body (the 99991790719601 rule).
    expect(writer).toMatch(/pg_get_functiondef\(p\.oid\)/);
    expect(writer).not.toMatch(
      /create\s+(or\s+replace\s+)?function\s+public\.refresh_business_brand_quality/i,
    );
    // …and that it is actually RUN. Without this, gutting the execute to a
    // no-op leaves every other assertion in this file green while the
    // migration changes nothing — it survived the first mutation round.
    expect(writer).toMatch(/execute replace\(v_src, v_from, v_to\);/);
  });

  it('removes exactly the two columns and keeps the two the job owns', () => {
    const from = writer.match(/v_from\s+text\s*:=\s*'([^']*)'/)?.[1] ?? '';
    const to = writer.match(/v_to\s+text\s*:=\s*'([^']*)'/)?.[1] ?? '';
    expect(from).toContain('completeness_score=coalesce(d.score,0)');
    expect(from).toContain('needs_attention=coalesce(d.score,0)<60');
    // The replacement keeps the cursor and the dimension detail.
    expect(to).toContain('quality_dimensions=d.dimensions');
    expect(to).toContain('quality_checked_at=now()');
    expect(to).not.toContain('completeness_score');
    expect(to).not.toContain('needs_attention');
  });

  it('refuses to replace unless the anchor occurs exactly once', () => {
    // A blind replace across a 200-line function is how you silently rewrite
    // the marketplace_brands arm instead.
    expect(writer).toMatch(/v_hits\s*<>\s*1/);
    expect(writer).toMatch(/raise exception[^;]*anchor occurs/i);
  });

  it('is soft on preconditions — an already-patched function is a no-op', () => {
    // An exact-match premise turns a concurrent sibling repair into a `db push`
    // abort that blocks every migration queued behind it.
    // Scoped to the branch, not the file: a bare /raise notice/ was satisfied
    // by the "does not exist" branch further up and stayed green when this one
    // was turned into an exception — it survived the first mutation round.
    expect(writer).toMatch(/raise notice '[^']*already patched/i);
  });

  it('asserts the organizations UPDATE no longer writes either column', () => {
    expect(writer).toMatch(/P1 failed[^']*completeness_score/i);
    expect(writer).toMatch(/P1 failed[^']*needs_attention/i);
    // Scoped to the organizations UPDATE: the brands arm keeps its own columns.
    expect(writer).toMatch(
      /substring\(v_src from position\('update organizations o set' in v_src\)\)/,
    );
  });

  it('asserts the statement still writes what it owns, so a deletion also fails', () => {
    expect(writer).toMatch(/P2 failed[^']*quality_dimensions/i);
    expect(writer).toMatch(/P3 failed[^']*marketplace_brands/i);
  });

  it('asserts the SURVIVING writer still exists and still guards its writes', () => {
    // Without P4, "one writer" is satisfied by there being none — and without
    // the IS DISTINCT FROM half, the sole writer would churn every night.
    expect(writer).toMatch(/P4 failed[^']*does not exist/i);
    expect(writer).toMatch(/completeness_score = s\.new_completeness/);
    expect(writer).toMatch(/needs_attention {4}= \(s\.new_completeness < 40\)/);
    expect(writer).toMatch(/P4 failed[^']*change guard/i);
  });
});

describe('99991791966722 — the organizations search trigger compares values', () => {
  /** The WHEN clause of the UPDATE trigger, from the statement only. */
  const whenClause = (() => {
    const start = trigger.indexOf('when (');
    const end = trigger.indexOf('execute function', start);
    expect(start).toBeGreaterThanOrEqual(0);
    expect(end).toBeGreaterThan(start);
    return trigger.slice(start, end);
  })();

  it('drops the unscoped trigger', () => {
    expect(trigger).toMatch(
      /drop trigger if exists trg_search_documents_organization on public\.organizations/,
    );
  });

  it('covers every column search_documents_index_organizations reads', () => {
    // The drift check. A column the indexer reads but the trigger does not
    // compare is a change that silently never reaches search — the quiet
    // direction, and the one worth a test.
    const files = readdirSync(MIGRATIONS)
      .filter((f) => f.endsWith('.sql'))
      .sort();
    const indexerFile = [...files]
      .reverse()
      .find((f) =>
        /create\s+(or\s+replace\s+)?function\s+public\.search_documents_index_organizations\s*\(/i.test(
          read(f),
        ),
      );
    expect(indexerFile).toBeDefined();

    const indexer = statementsOnly(read(indexerFile!));
    const start = indexer.search(
      /create\s+(or\s+replace\s+)?function\s+public\.search_documents_index_organizations\s*\(/i,
    );
    // Bound the slice to THIS function. Running to EOF swallowed the two
    // functions defined after it in the same file, and `get_organization`
    // references `o.safety_gated` — which the indexer does not — so the first
    // draft of this check failed on correct code. An anchor wider than the
    // claim is the recurring defect in this repo's guard tests; here it failed
    // loudly, but the same width in a negative assertion passes silently.
    const after = indexer
      .slice(start + 1)
      .search(/\ncreate\s+(or\s+replace\s+)?(function|trigger|view)\b/i);
    const body = after === -1 ? indexer.slice(start) : indexer.slice(start, start + 1 + after);
    const cols = new Set(
      [...body.matchAll(/\bo\.([a-z_]+)/g)].map((m) => m[1]).filter((c) => c !== 'id'),
    );

    // Positive control: an indexer that matched nothing would make the loop
    // below pass over an empty set.
    expect(cols.size).toBeGreaterThanOrEqual(15);

    const missing = [...cols].filter((c) => !whenClause.includes(`new.${c}`));
    expect(missing).toEqual([]);
  });

  it('compares old to new rather than merely naming the columns', () => {
    // `UPDATE OF (cols)` fires on the columns named in the STATEMENT, not on
    // what changed, so the column list alone would have changed nothing:
    // refresh names completeness_score in its SET on every row.
    const comparisons = [...whenClause.matchAll(/is distinct from/g)].length;
    expect(comparisons).toBeGreaterThanOrEqual(15);
    // …and no short circuit. `when (true or old.name is distinct from …)`
    // restores the original defect while leaving the column coverage, the
    // comparison count and the `WHEN` keyword all intact — it survived the
    // first mutation round. Asserting the condition is not enough when the
    // predicate can be neutered instead.
    expect(whenClause).not.toMatch(/\b(true|false)\b/i);
  });

  it('leaves INSERT and DELETE unconditional', () => {
    const ins = trigger.slice(
      trigger.indexOf('create trigger trg_search_documents_organization_ins'),
      trigger.indexOf('create trigger trg_search_documents_organization_del'),
    );
    const del = trigger.slice(
      trigger.indexOf('create trigger trg_search_documents_organization_del'),
      trigger.indexOf('create trigger trg_search_documents_organization_upd'),
    );
    expect(ins).not.toMatch(/\bwhen\s*\(/);
    expect(del).not.toMatch(/\bwhen\s*\(/);
    expect(ins).toMatch(/after insert on public\.organizations/);
    expect(del).toMatch(/after delete on public\.organizations/);
  });

  it('retries the swap under a short lock_timeout instead of stalling the table', () => {
    // A pending ACCESS EXCLUSIVE queues every NEW reader behind it, and the
    // reindex drain holds a read lock for most of every minute, so an
    // unbounded wait stalls organizations site-wide. A bare lock_timeout is
    // the other failure: it turns a busy minute into a repo-wide `db push`
    // abort.
    expect(trigger).toMatch(/set local lock_timeout = '2s'/);
    expect(trigger).toMatch(/exception when lock_not_available then/);
    expect(trigger).toMatch(/v_attempt >= v_max/);
    expect(trigger).toMatch(/pg_sleep\(2\)/);
  });

  it('asserts the coverage check again at apply time, against the live indexer', () => {
    // The repo test above reads the migration that last defined the indexer;
    // this one reads what is actually installed. They can disagree.
    expect(trigger).toMatch(/P3 failed[^']*does not compare/i);
    expect(trigger).toMatch(/P3b failed[^']*proved nothing/i);
    expect(trigger).toMatch(/P4 failed[^']*no WHEN clause/i);
    expect(trigger).toMatch(/P5 failed[^']*unconditional/i);
  });

  it('asserts the old trigger is really gone, not merely replaced alongside', () => {
    expect(trigger).toMatch(/P2 failed[^']*still exists/i);
  });
});
