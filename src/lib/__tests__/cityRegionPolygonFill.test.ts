import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// Guards 99991791713213_city_region_polygon_fill.sql, the generator it mirrors
// and its health-script block.
//
// What must not drift:
//   1. the runner only FILLS: region_code IS NULL and region_name empty, both at
//      selection and again in the UPDATE — a polygon never overwrites a code;
//   2. a country is filled only when its existing codes agree >= 95% over >= 5
//      calibration rows (AR, MA, IR, RS fail that by structure, not by noise);
//   3. a point in another country's polygon, or near another first-level unit,
//      is stamped and left alone;
//   4. the polygon code is climbed to the FIRST level (Natural Earth's admin1 is
//      a department/province in FR, ES, GB, IT, BE);
//   5. the stamp is merged with `||`, never a whole-object write-back;
//   6. runner + sentinel are service_role only, and the FR parent fixes live in
//      both the migration and the generator.

const MIGRATION = '99991791713213_city_region_polygon_fill.sql';
const raw = readFileSync(join(process.cwd(), 'supabase/migrations', MIGRATION), 'utf8');
const generator = readFileSync(
  join(process.cwd(), 'scripts/data-quality/generate-geo-subdivisions.mjs'),
  'utf8',
);
const health = readFileSync(join(process.cwd(), 'scripts/check-pipeline-health.mjs'), 'utf8');

/** Migration text with comment lines removed, so prose cannot satisfy a guard. */
const statements = raw
  .split('\n')
  .filter((l) => !l.trimStart().startsWith('--'))
  .join('\n');

const lookup = statements.slice(
  statements.indexOf('create or replace function public.city_region_polygon_lookup'),
  statements.indexOf('create or replace function public.run_city_region_polygon_fill'),
);
const runner = statements.slice(
  statements.indexOf('create or replace function public.run_city_region_polygon_fill'),
  statements.indexOf('create or replace function public.city_region_polygon_signals'),
);
const candidates = runner.slice(
  runner.indexOf('create temp table _rpf_cand'),
  runner.indexOf('select count(*) into v_examined'),
);
const update = runner.slice(runner.indexOf('update public.cities c'), runner.indexOf('get diagnostics'));
const sentinel = statements.slice(
  statements.indexOf('create or replace function public.city_region_polygon_signals'),
  statements.indexOf('insert into public.admin_automations'),
);
const verify = statements.slice(statements.indexOf('do $verify$'));

describe('the spans this file depends on', () => {
  it('found all of them', () => {
    for (const s of [lookup, runner, candidates, update, sentinel, verify]) {
      expect(s.length).toBeGreaterThan(40);
    }
  });
});

describe('fill-if-empty', () => {
  it('selects only cities with no code and no region name', () => {
    expect(candidates).toMatch(/c\.region_code is null/);
    expect(candidates).toMatch(/nullif\(btrim\(c\.region_name\), ''\) is null/);
    expect(candidates).toMatch(/not \(coalesce\(c\.enrichment_status, '\{\}'::jsonb\) \? 'region_polygon'\)/);
  });
  it('re-checks emptiness in the UPDATE itself', () => {
    const where = update.slice(update.indexOf('where c.id = r.id'));
    expect(where).toMatch(/and c\.region_code is null/);
    expect(where).toMatch(/and nullif\(btrim\(c\.region_name\), ''\) is null/);
  });
  it('writes a code only for the filled state', () => {
    expect(update).toMatch(/region_code = case when r\.state = 'filled' then r\.top else c\.region_code end/);
  });
  it('writes region_name only when the name resolves back to the same code', () => {
    expect(update).toMatch(/public\.resolve_region_code\(r\.cc, r\.sub_name\) = r\.top/);
  });
  it('merges the stamp with || and caps the batch at 300', () => {
    expect(update).toMatch(/coalesce\(c\.enrichment_status, '\{\}'::jsonb\)\s*\|\| jsonb_build_object\('region_polygon'/);
    expect(runner).toMatch(/least\(greatest\(coalesce\(p_batch, 300\), 1\), 300\)/);
  });
});

describe('gates', () => {
  it('climbs the polygon code to the first level, same country only', () => {
    expect(lookup).toMatch(/when split_part\(g\.iso_3166_2, '-', 1\) = p_cc then/);
    expect(lookup).toMatch(/public\.geo_subdivision_root\(g\.iso_3166_2\)/);
    expect(runner).toMatch(/s\.parent_code is null/);
  });
  it('refuses a polygon from another country', () => {
    expect(runner).toMatch(/when l\.polygon_country <> k\.cc then 'other_country'/);
  });
  it('requires per-country calibration of >= 5 rows at >= 95%', () => {
    expect(runner).toMatch(/when coalesce\(t\.n, 0\) < 5 or t\.agree::numeric \/ t\.n < 0\.95 then 'country_untrusted'/);
  });
  it('skips points near another first-level unit', () => {
    expect(runner).toMatch(/st_dwithin\(o\.geom, k\.pt, 0\.03\)/);
    expect(runner).toMatch(/is distinct from l\.region_code\s*\) then 'ambiguous_border'/);
  });
  it('orders the gates so filled is only the fall-through', () => {
    const order = ['no_polygon', 'other_country', 'no_code', 'country_untrusted', 'ambiguous_border', "else 'filled'"];
    const pos = order.map((s) => runner.indexOf(s));
    for (let i = 1; i < pos.length; i++) expect(pos[i]).toBeGreaterThan(pos[i - 1]);
  });
});

describe('vocabulary fixes', () => {
  it('lives in the migration', () => {
    expect(statements).toMatch(/set parent_code = 'FR-BFC'\s+where code = 'FR-70'/);
    expect(statements).toMatch(/set parent_code = 'FR-IDF'\s+where code = 'FR-75C'/);
  });
  it('lives in the generator too', () => {
    expect(generator).toMatch(/'FR-70': 'FR-BFC'/);
    expect(generator).toMatch(/'FR-75C': 'FR-IDF'/);
  });
});

describe('privileges and wiring', () => {
  it('revokes runner, lookup and sentinel from anon/authenticated', () => {
    for (const sig of [
      'city_region_polygon_lookup\\(text, geometry\\)',
      'run_city_region_polygon_fill\\(integer, boolean\\)',
      'city_region_polygon_signals\\(\\)',
    ]) {
      expect(statements).toMatch(new RegExp(`revoke all on function public\\.${sig} from public, anon, authenticated;`));
    }
  });
  it('asserts the dry run writes nothing and the grants hold', () => {
    expect(verify).toMatch(/run_city_region_polygon_fill\(50, true\)/);
    expect(verify).toMatch(/\(v_res ->> 'written'\)::int <> 0/);
    expect(verify).toMatch(/has_function_privilege\('anon', 'public\.run_city_region_polygon_fill/);
  });
  it('is scheduled through the registry', () => {
    expect(statements).toMatch(/'command', 'select public\.run_city_region_polygon_fill\(300\)'/);
    expect(statements).toMatch(/public\.admin_automation_effective_command\(\s*'city_region_polygon_fill'/);
  });
  it('health script fails on a wrong-country fill, before the terminal exit', () => {
    const at = health.indexOf('/rpc/city_region_polygon_signals');
    expect(at).toBeGreaterThan(0);
    const block = health.slice(at, at + 1800);
    expect(block).toMatch(/Number\(poly\.filled_wrong_country\) > 0\) \{\s*console\.error[^\n]*\n\s*FAILED = true/);
    expect(at).toBeLessThan(health.lastIndexOf('process.exit(1)'));
  });
});
