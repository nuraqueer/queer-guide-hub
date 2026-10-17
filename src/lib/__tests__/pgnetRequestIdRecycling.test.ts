import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// Guard for 99991792211841_pgnet_request_id_recycling.
//
// pg_net's request-id sequence reset on 2026-10-12 and began replaying ids
// that public.admin_automation_run_requests already held. request_id was that
// table's PRIMARY KEY and automation_http_post filed with
// `on conflict (request_id) do nothing`, so a collision SILENTLY DROPPED the
// filing; the run then had zero requests, which the reaper books as a
// legitimate conditional no-op — a permanent green that can neither
// auto-pause nor record a real failure. 0.6% of runs/day before, 62.8% after.
const MIGRATION = '99991792211841_pgnet_request_id_recycling.sql';

const ROOT = join(__dirname, '..', '..', '..');
const sql = readFileSync(join(ROOT, 'supabase/migrations', MIGRATION), 'utf8');
const health = readFileSync(join(ROOT, 'scripts/check-pipeline-health.mjs'), 'utf8');

// This migration's header quotes the defect verbatim — including the old
// `on conflict (request_id) do nothing` — so every negative assertion below
// has to run against statements, never the raw file. A `not.toContain` over
// unstripped source is satisfied by the comment and proves nothing.
const statements = sql
  .split('\n')
  .filter((line) => !line.trimStart().startsWith('--'))
  .join('\n');

describe('pg_net request id recycling', () => {
  it('the header still quotes the defect, so comment-stripping is load-bearing', () => {
    // A positive control on the stripper itself: if this stops being true the
    // negative assertions below have gone vacuous for the opposite reason.
    expect(sql).toContain('on conflict (request_id) do nothing');
    expect(statements).not.toContain('on conflict (request_id) do nothing');
  });

  it('keys the filing table on the pair, not on the recycled pg_net id', () => {
    expect(statements).toMatch(
      /alter table public\.admin_automation_run_requests\s+drop constraint admin_automation_run_requests_pkey,\s+add constraint admin_automation_run_requests_pkey primary key \(run_id, request_id\)/,
    );
  });

  it('files on the new key — a leftover (request_id) target raises 42P10 inside the cron command', () => {
    const fn = statements.slice(
      statements.indexOf('create or replace function public.automation_http_post'),
      statements.indexOf('CREATE OR REPLACE FUNCTION public.admin_automation_reap_runs'),
    );
    expect(fn).toContain('on conflict (run_id, request_id) do nothing');
    expect(fn).not.toMatch(/on conflict \(request_id\)/);
  });

  it('bounds the reaper response join in time, and fails open on an unstamped row', () => {
    // A recycled id is no longer exact, so a run still 'running' from before a
    // reset could otherwise be resolved against a fresh, unrelated response.
    expect(statements).toMatch(
      /LEFT JOIN net\._http_response resp\s+ON resp\.id = req\.request_id\s+AND \(req\.created_at IS NULL OR resp\.created >= req\.created_at\)/,
    );
  });

  it('reports no_request BESIDE its denominator', () => {
    const gaps = statements.slice(statements.indexOf("'no_request_24h'"));
    expect(gaps).toContain("'finished', count(*)");
    expect(gaps).toMatch(
      /'no_request', count\(\*\) FILTER \(WHERE \(summary->>'no_request'\)::boolean\)/,
    );
  });

  it('proves the fix behaviourally, not structurally', () => {
    // Asserting the constraint definition passes against a migration that
    // swapped the key and left the writer targeting the old one. The probe
    // files one pg_net id against two runs and demands both land.
    const verify = statements.slice(statements.indexOf('do $verify$'));
    expect(verify).toMatch(
      /insert into public\.admin_automation_run_requests[\s\S]{0,400}v_probe_id, v_run_a[\s\S]{0,200}v_probe_id, v_run_b/,
    );
    expect(verify).toContain('if v_landed <> 2 then');
    expect(verify).toContain(
      'delete from public.admin_automation_run_requests where request_id = v_probe_id',
    );
  });

  it('never writes admin_automation_runs in the probe', () => {
    // Its finish trigger resets consecutive_failures and last_run_status on
    // the parent automation — a probe must not clear a real job's failure
    // count as a side effect.
    const verify = statements.slice(statements.indexOf('do $verify$'));
    expect(verify).not.toMatch(/insert into public\.admin_automation_runs/i);
    expect(verify).not.toMatch(/update public\.admin_automation_runs/i);
  });
});

describe('check-pipeline-health no_request gate', () => {
  const block = health.slice(
    health.indexOf('const noReq = gaps.no_request_24h'),
    health.indexOf('const unverifiable = gaps.unverifiable_automations'),
  );

  it('is wired at all', () => {
    expect(block.length).toBeGreaterThan(0);
  });

  it('hard-fails on an absent key rather than reading it as clean', () => {
    expect(block).toMatch(/if \(!noReq \|\| noReq\.finished === undefined\)/);
    // Anchor on the CONDITION and on FAILED, not on the message text: a
    // neutered `if (false)` leaves every string intact.
    expect(block.match(/FAILED = true/g) ?? []).toHaveLength(3);
  });

  it('hard-fails on a dead reaper, which also produces zero no_request', () => {
    expect(block).toMatch(/Number\(noReq\.finished\) === 0/);
  });

  it('gates on the rate at the measured 5% threshold, not on a zero invariant', () => {
    expect(block).toMatch(/Number\(noReq\.pct\) > 5(?!\d)/);
    expect(block).toContain('0.6%');
  });
});
