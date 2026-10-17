/**
 * Guards 99991792224368_admin_counts_cache.sql.
 *
 * `get_admin_counts()` was 4.9% of all database execution time — ~44
 * full-corpus aggregates re-run on every poll from every open admin tab. The
 * fix caches the payload. What these tests protect is not "a cache exists" but
 * the three properties that make it safe:
 *
 *   1. the cache stores the WHOLE jsonb payload, never per-key columns, so the
 *      key set cannot drift when a `triage_sources` row is added;
 *   2. the reader still performs the role check and still exposes
 *      `counts_as_of`, so staleness is visible rather than hidden;
 *   3. the migration's own postcondition compares the cached key set against a
 *      LIVE compute — `adminQueues.test.ts` asserts TS config against a
 *      hardcoded TS list and never calls the RPC, so it cannot catch a cache
 *      that lost keys.
 *
 * Assertions run against COMMENT-STRIPPED sql: this migration's header quotes
 * several of the strings below, and an unstripped `toContain` would be
 * satisfied by the prose while the statement was gone.
 */
import { describe, expect, it } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const MIGRATION = '99991792224368_admin_counts_cache.sql';
const MIGRATIONS_DIR = join(process.cwd(), 'supabase', 'migrations');

function migrationSql(): string {
  const file = readdirSync(MIGRATIONS_DIR).find((f) => f === MIGRATION);
  if (!file) throw new Error(`${MIGRATION} not found — was it renumbered?`);
  return readFileSync(join(MIGRATIONS_DIR, file), 'utf8');
}

/** Strip `--` line comments so header prose cannot satisfy an assertion. */
function statements(): string {
  return migrationSql()
    .split('\n')
    .filter((l) => !l.trimStart().startsWith('--'))
    .join('\n');
}

describe('admin counts cache migration', () => {
  it('is present under the version the test names', () => {
    expect(() => migrationSql()).not.toThrow();
  });

  it('caches the whole payload rather than per-key columns', () => {
    const sql = statements();
    expect(sql).toMatch(/create table if not exists public\.admin_counts_cache/i);
    expect(sql).toMatch(/payload\s+jsonb\s+not null/i);
    // A singleton: one row, enforced, not "latest by timestamp".
    expect(sql).toMatch(/id\s+boolean\s+primary key/i);
    expect(sql).toMatch(/admin_counts_cache_singleton check \(id\)/i);
  });

  it('computes with the original expressions, not a reimplementation', () => {
    const sql = statements();
    // The loop over triage_sources is what makes the key set dynamic; if a
    // future edit replaces it with a fixed list, the cache silently stops
    // covering newly registered sources.
    expect(sql).toMatch(/from triage_sources where active order by queue_key loop/i);
    expect(sql).toMatch(/count\(\*\) filter\(where created_at < now\(\) - %L::interval\)/i);
    expect(sql).toMatch(/'sla_hours',v_sla/i);
  });

  it('keeps the role check on the reader and keeps compute internal', () => {
    const sql = statements();
    const reader = sql.slice(sql.indexOf('create or replace function public.get_admin_counts'));
    expect(reader).toMatch(/has_any_role_jwt\(array\['admin'::app_role,'moderator'::app_role\]\)/);
    expect(reader).toMatch(/errcode='42501'/);
    // The compute helper bypasses the check, so it must not be callable by a
    // logged-in user directly.
    expect(sql).toMatch(
      /revoke all on function public\.admin_counts_compute\(\) from public, anon, authenticated/i,
    );
    expect(sql).toMatch(
      /revoke all on function public\.refresh_admin_counts\(\) from public, anon, authenticated/i,
    );
    expect(sql).toMatch(/revoke all on table public\.admin_counts_cache from anon, authenticated/i);
  });

  it('exposes counts_as_of so cache lag is visible', () => {
    const reader = statements().slice(
      statements().indexOf('create or replace function public.get_admin_counts'),
    );
    expect(reader).toMatch(/jsonb_build_object\('counts_as_of', v_as_of\)/);
  });

  it('falls back to a live compute only when the cache is EMPTY, not when stale', () => {
    const reader = statements().slice(
      statements().indexOf('create or replace function public.get_admin_counts'),
    );
    expect(reader).toMatch(/if v_payload is null then/i);
    expect(reader).toMatch(/v_payload := public\.admin_counts_compute\(\)/);
    // A staleness-triggered recompute would reintroduce the thundering herd the
    // cache exists to prevent: six polling tabs each recomputing when the cron
    // is down. Serving a stale number with its age is the deliberate choice.
    expect(reader).not.toMatch(/computed_at\s*<\s*now\(\)\s*-/i);
  });

  it('serialises the refresher with a non-blocking advisory lock', () => {
    const sql = statements();
    expect(sql).toMatch(/pg_try_advisory_xact_lock\(hashtext\('admin_counts_refresh'\)\)/);
    // try, not blocking — a queued pg_cron worker turns a stall into a pile-up.
    expect(sql).not.toMatch(/pg_advisory_xact_lock\(hashtext\('admin_counts_refresh'\)\)/);
  });

  it('registers the job in admin_automations and schedules it at */5', () => {
    const sql = statements();
    expect(sql).toMatch(/insert into public\.admin_automations/i);
    expect(sql).toMatch(/'admin_counts_refresh'/);
    expect(sql).toMatch(/cron\.schedule\('admin_counts_refresh', ?'\*\/5 \* \* \* \*'/);
    // Registry is the record of truth; an rpc row carries no action.command the
    // reconciler can reschedule from, so the migration schedules it directly.
    expect(sql).toMatch(/'type','rpc'/);
    // Never DELETE a registry row; re-running must repoint, not duplicate.
    expect(sql).toMatch(/on conflict \(slug\) do update/i);
    expect(sql).not.toMatch(/delete from public\.admin_automations/i);
  });

  it('seeds the cache so the first post-deploy call is not a herd', () => {
    expect(statements()).toMatch(/select public\.refresh_admin_counts\(\)/i);
  });

  it('asserts the cached key set against a LIVE compute, not a hardcoded list', () => {
    const verify = statements().slice(statements().indexOf('do $verify$'));
    expect(verify).toMatch(/jsonb_object_keys\(public\.admin_counts_compute\(\)\)/);
    expect(verify).toMatch(/v_cached is distinct from v_live/);
    expect(verify).toMatch(/raise exception/i);
    // The reader itself must be exercised; a migration carries no JWT, so the
    // role check would raise 42501 first and the assertion would be vacuous.
    expect(verify).toMatch(/set_config\('request\.jwt\.claims'/);
    expect(verify).toMatch(/public\.get_admin_counts\(\)/);
  });
});

describe('useAdminCounts type contract', () => {
  const hook = readFileSync(join(process.cwd(), 'src', 'hooks', 'useAdminCounts.ts'), 'utf8');

  it('declares the two non-numeric keys the payload carries', () => {
    // Typing the payload as a bare Record<string, number> is a lie the file's
    // own docstring already calls out for sla_hours; counts_as_of is a string
    // and belongs in the same exception list.
    expect(hook).toMatch(/sla_hours\?: Record<string, number>;/);
    expect(hook).toMatch(/counts_as_of\?: string;/);
  });
});
