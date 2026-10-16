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

/**
 * The command literal ONLY — between `v_cmd := $cmd$` and its closing `$cmd$`.
 *
 * Scoping matters: `legacy_anon_key`, `Authorization`, `X-Internal-Secret` and
 * `internal_invoke_secret` all appear a SECOND time in the postconditions that
 * check for them. A whole-file `toContain` therefore matches the check while
 * the header it guards has been deleted — mutation "cron drops Authorization
 * bearer" SURVIVED exactly that way before this was added.
 */
const CMD = (() => {
  const open = MIG.indexOf('$cmd$');
  const close = MIG.indexOf('$cmd$', open + 5);
  if (open === -1 || close === -1) throw new Error('v_cmd $cmd$ literal not found');
  return MIG.slice(open + 5, close);
})();

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

  it('positive control: the postconditions also mention these strings', () => {
    // This is WHY the two tests below scope to CMD. If the postconditions ever
    // stop naming them, CMD-scoping is no longer load-bearing and these tests
    // are weaker than they look — fail loudly so someone re-reads them.
    const checks = MIG.slice(MIG.indexOf('$verify$'));
    expect(checks).toContain('legacy_anon_key');
    expect(checks).toContain('X-Internal-Secret');
  });

  it('the command literal sends X-Internal-Secret from Vault', () => {
    expect(CMD).toContain('X-Internal-Secret');
    expect(CMD).toContain('internal_invoke_secret');
  });

  it('the command literal KEEPS the Authorization bearer', () => {
    // Dropping it reopens the deploy-order window: db push runs before
    // functions deploy, so the new command is briefly live against the old
    // function, which still demands a JWT.
    expect(CMD).toContain('legacy_anon_key');
    expect(CMD).toMatch(/'Authorization',\s*'Bearer '/);
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
