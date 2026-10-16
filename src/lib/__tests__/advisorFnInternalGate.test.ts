/**
 * Guards the auth posture of `sync-supabase-advisors`.
 *
 * It ran with `verify_jwt = true` and no gate of its own. That is weaker than
 * it looks: verify_jwt proves a JWT is VALID, never what role it carries, and
 * the publishable anon key is public — it ships in the client bundle. Measured
 * on prod 2026-10-16, a plain curl with that key ran the function, which writes
 * `api_error` rows and auto-resolves others.
 *
 * ALL SOURCE ASSERTIONS RUN OVER COMMENT-STRIPPED TEXT. The function header,
 * the config.toml comment and the migration header all quote the very strings
 * being asserted ("verify_jwt", "X-Internal-Secret", "legacy_anon_key") while
 * explaining the change, so a `toContain` over raw text passes with the
 * executable line deleted.
 */
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = (p: string) => resolve(__dirname, '../../../', p);

function stripTs(src: string): string {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .split('\n')
    .map((l) => l.replace(/\/\/.*$/, ''))
    .join('\n');
}
function stripSql(sql: string): string {
  return sql
    .split('\n')
    .filter((l) => !l.trimStart().startsWith('--'))
    .join('\n');
}

const FN_RAW = readFileSync(root('supabase/functions/sync-supabase-advisors/index.ts'), 'utf8');
const FN = stripTs(FN_RAW);
const TOML = readFileSync(root('supabase/config.toml'), 'utf8');
const MIG_RAW = readFileSync(
  root('supabase/migrations/99991792180494_advisor_fn_internal_secret_gate.sql'),
  'utf8',
);
const MIG = stripSql(MIG_RAW);

describe('sync-supabase-advisors auth gate', () => {
  it('positive control: the headers really do quote these strings', () => {
    // If this fails, the stripping below is guarding nothing.
    expect(FN_RAW).toContain('verify_jwt');
    expect(MIG_RAW.length).toBeGreaterThan(MIG.length);
    expect(FN_RAW.length).toBeGreaterThan(FN.length);
  });

  it('the function self-gates with requireInternalOrAdmin', () => {
    expect(FN).toMatch(
      /import\s*\{\s*requireInternalOrAdmin\s*\}\s*from\s*'\.\.\/_shared\/supabase-client\.ts'/,
    );
    expect(FN).toMatch(/await requireInternalOrAdmin\(req,\s*svc\)/);
    // The Response branch must actually return, or the gate is decorative.
    expect(FN).toMatch(/if\s*\(auth instanceof Response\)\s*return auth;/);
  });

  it('gates BEFORE the advisor pull and before any write', () => {
    // An unauthorised caller must cost nothing — not a Management-API fetch,
    // and certainly not an upsert.
    const gate = FN.indexOf('requireInternalOrAdmin(req');
    const fetchCall = FN.indexOf('fetchAdvisors(ref, pat');
    const upsert = FN.indexOf("rpc('upsert_api_error'");
    expect(gate).toBeGreaterThan(-1);
    expect(fetchCall).toBeGreaterThan(-1);
    expect(upsert).toBeGreaterThan(-1);
    expect(gate).toBeLessThan(fetchCall);
    expect(gate).toBeLessThan(upsert);
  });

  it('config.toml turns the gateway JWT off for this slug', () => {
    // Scope to this function's own block — a bare search for "verify_jwt =
    // false" matches ~60 other functions.
    const i = TOML.indexOf('[functions.sync-supabase-advisors]');
    expect(i).toBeGreaterThan(-1);
    const next = TOML.indexOf('[functions.', i + 1);
    const block = TOML.slice(i, next === -1 ? undefined : next);
    expect(block).toMatch(/^verify_jwt = false$/m);
  });

  it('the cron sends X-Internal-Secret from Vault', () => {
    expect(MIG).toContain('X-Internal-Secret');
    expect(MIG).toContain('internal_invoke_secret');
  });

  it('the cron KEEPS the Authorization bearer', () => {
    // Dropping it reopens the deploy-order window: db push runs before
    // functions deploy, so the new command is briefly live against the old
    // function, which still demands a JWT.
    expect(MIG).toContain('legacy_anon_key');
    expect(MIG).toContain('Authorization');
  });

  it('uses the two-argument effective-command helper', () => {
    // The one-arg form does not exist; calling it is a 42883 at apply time,
    // which aborts db push for the whole repo. Caught by the prod dry run.
    expect(MIG).toMatch(
      /admin_automation_effective_command\(\s*'sync_supabase_advisors_hourly'\s*,\s*v_cmd\s*\)/,
    );
    expect(MIG).not.toMatch(/admin_automation_effective_command\(\s*'[a-z_]+'\s*\)/);
  });

  it('updates BOTH the registry and the live cron', () => {
    expect(MIG).toMatch(/update public\.admin_automations/);
    expect(MIG).toMatch(/cron\.alter_job/);
  });

  it('aborts rather than locking the cron out if the vault secret is gone', () => {
    expect(MIG).toMatch(/if v_secret is null or length\(v_secret\) = 0 then/);
    expect(MIG).toMatch(/raise exception 'ABORT[^']*internal_invoke_secret/);
  });

  it('postconditions assert the reached state, and raise', () => {
    for (const p of ['P1 failed', 'P1b failed', 'P2 failed', 'P3 failed', 'P4 failed']) {
      expect(MIG).toContain(p);
    }
    // Assert the branches RAISE, not merely that the strings exist — a
    // condition left standing over a gutted body still matches a toContain.
    const raises = MIG.match(/raise exception 'P\d/g) ?? [];
    expect(raises.length).toBeGreaterThanOrEqual(5);
    // No short-circuit that would make the verify block vacuous.
    expect(MIG).not.toMatch(/if\s+false\s+then/i);
  });
});
