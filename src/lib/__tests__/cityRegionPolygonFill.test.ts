import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// Guards 99991791735851_city_region_polygon_fill.sql, the generator it mirrors
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

const MIGRATION = '99991791735851_city_region_polygon_fill.sql';
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

const helper = statements.slice(
  statements.indexOf('create or replace function public.geo_boundary_region'),
  statements.indexOf('create or replace function public.city_region_polygon_lookup'),
);
const crosswalk = statements.slice(
  statements.indexOf('insert into public.geo_boundary_region_map'),
  statements.indexOf('create temp table _ar_swap'),
);
const arRepair = statements.slice(
  statements.indexOf('create temp table _ar_swap'),
  statements.indexOf('create temp table _bd_num'),
);
const bdRepair = statements.slice(
  statements.indexOf('create temp table _bd_num'),
  statements.indexOf('create or replace function public.geo_boundary_region'),
);
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
    for (const s of [helper, crosswalk, arRepair, bdRepair, lookup, runner, candidates, update, sentinel, verify]) {
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
  it('climbs the polygon code to the first level, same country only, crosswalk first', () => {
    expect(helper).toMatch(/case when split_part\(g\.iso_3166_2, '-', 1\) = p_cc then/);
    expect(helper).toMatch(/case when m\.polygon_code is not null then m\.region_code\s+else coalesce\(public\.geo_subdivision_root\(g\.iso_3166_2\)/);
    expect(lookup).toMatch(/public\.geo_boundary_region\(g\.id, p_cc\)/);
    expect(runner).toMatch(/s\.parent_code is null/);
  });
  it('refuses a polygon from another country', () => {
    expect(runner).toMatch(/when l\.polygon_country <> k\.cc then 'other_country'/);
  });
  it('trusts a country on calibration (>= 5 rows, >= 95%) or, with zero disagreements, on structure (>= 95%)', () => {
    expect(runner).toMatch(/\(coalesce\(h\.n, 0\) >= 5 and h\.agree::numeric \/ h\.n >= 0\.95\)/);
    expect(runner).toMatch(/or \(coalesce\(h\.n, 0\) = coalesce\(h\.agree, 0\)\s+and coalesce\(st\.mapped::numeric \/ nullif\(st\.polys, 0\), 0\) >= 0\.95\)\) as trusted/);
    expect(runner).toMatch(/when not coalesce\(t\.trusted, false\) then 'country_untrusted'/);
  });
  it('calibrates only on cities the fill itself would not skip as border cases', () => {
    const cal = runner.slice(runner.indexOf('), hit as ('), runner.indexOf('), structure as ('));
    expect(cal).toMatch(/where not exists \(/);
    expect(cal).toMatch(/st_dwithin\(o\.geom, cal\.pt, 0\.03\)/);
  });
  it('counts a polygon as structurally mapped only by code AND name, or by crosswalk', () => {
    const st = runner.slice(runner.indexOf('), structure as ('), runner.indexOf('select k.cc'));
    expect(st).toMatch(/m\.polygon_code is not null\s+or \(s\.code is not null\s+and \(public\.city_name_key\(s\.name\) = public\.city_name_key\(g\.name\)/);
  });
  it('skips points near another first-level unit', () => {
    expect(runner).toMatch(/st_dwithin\(o\.geom, k\.pt, 0\.03\)/);
    // neighbours are resolved through the same crosswalk, or IR/MA neighbours
    // would read as another unit and block every point
    expect(runner).toMatch(/coalesce\(public\.geo_boundary_region\(o\.id, k\.cc\), o\.iso_3166_2\)/);
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
    expect(generator).toMatch(/'MA-NOU': 'MA-06', 'MA-CHT': 'MA-09'/);
  });
});

describe('crosswalk', () => {
  const rows = [...crosswalk.matchAll(/\('([A-Z]{2}-\d{2})', '([^']+)', (null|'[A-Z]{2}-\d{2}'), '([a-z_0-9]+)'\)/g)];
  it('maps all 31 IR provinces exactly once', () => {
    const ir = rows.filter((r) => r[1].startsWith('IR-'));
    expect(ir).toHaveLength(31);
    expect(new Set(ir.map((r) => r[3])).size).toBe(31);
    expect(ir.every((r) => r[3] !== 'null')).toBe(true);
  });
  it('gives the two Natural Earth IR-07 polygons different provinces', () => {
    expect(crosswalk).toMatch(/\('IR-07', 'Alborz', 'IR-30'/);
    expect(crosswalk).toMatch(/\('IR-07', 'Tehran', 'IR-23'/);
  });
  it('maps 7 whole MA regions, refuses the 7 split ones and Western Sahara', () => {
    const ma = rows.filter((r) => r[1].startsWith('MA-'));
    expect(ma).toHaveLength(16);
    expect(ma.filter((r) => r[4] === 'pre_2015_region_within' && r[3] !== 'null')).toHaveLength(7);
    expect(ma.filter((r) => r[4] === 'pre_2015_region_split' && r[3] === 'null')).toHaveLength(7);
    const ws = ma.filter((r) => r[4] === 'disputed_western_sahara');
    expect(ws.map((r) => r[1]).sort()).toEqual(['MA-15', 'MA-16']);
    expect(ws.every((r) => r[3] === 'null')).toBe(true);
  });
});

describe('RS, BD, CO', () => {
  it('refuses the pre-2014 Panamá polygon and maps the Quezaltenango spelling', () => {
    expect(crosswalk).toMatch(/\('PA-8', 'Panama', null, 'pre_2014_province_split'\)/);
    expect(crosswalk).toMatch(/\('GT-QZ', 'Quezaltenango', 'GT-09', 'ne_spelling'\)/);
    for (const [code, name] of [['PA-4', 'Chiriquí'], ['PA-EM', 'Emberá'], ['PA-KY', 'Kuna Yala'], ['PA-NB', 'Ngöbe Buglé']]) {
      // a spelling row must point at the polygon's own code — it renames, it never re-files
      expect(crosswalk).toContain(`('${code}', '${name}', '${code}', 'ne_spelling')`);
    }
  });
  it('sends the mislabelled Bogotá polygon to CO-DC and refuses the pre-2015 Dhaka division', () => {
    expect(crosswalk).toMatch(/\('CO-CUN', 'Bogota', 'CO-DC', 'ne_mislabelled'\)/);
    expect(crosswalk).toMatch(/\('BD-C', 'Dhaka', null, 'pre_2015_division_split'\)/);
  });
  it('puts exactly the seven Vojvodina districts under RS-VO, in migration and generator', () => {
    expect(statements).toMatch(/set parent_code = 'RS-VO'\s+where code in \('RS-01', 'RS-02', 'RS-03', 'RS-04', 'RS-05', 'RS-06', 'RS-07'\)/);
    for (let i = 1; i <= 7; i++) expect(generator).toMatch(new RegExp(`'RS-0${i}': 'RS-VO'`));
    // Kosovo districts are not touched
    expect(statements).not.toMatch(/'RS-2[5-9]'[^\n]*'RS-KM'/);
    expect(generator).not.toMatch(/'RS-2[5-9]': 'RS-KM'/);
  });
  it('gives BD the GeoNames division numbers in migration and generator', () => {
    const pairs = [['BD-C', '81'], ['BD-D', '82'], ['BD-E', '83'], ['BD-B', '84'], ['BD-A', '85'], ['BD-G', '86'], ['BD-F', '87']];
    for (const [code, fips] of pairs) {
      expect(statements).toContain(`('${code}', '${fips}')`);
      expect(generator).toContain(`'${code}': '${fips}'`);
    }
  });
  it('resolves only numeric BD names with no code, and writes the readable name', () => {
    expect(bdRepair).toMatch(/c\.region_code is null\s+and c\.region_name ~ '\^\\s\*\[0-9\]\+\\s\*\$'/);
    expect(bdRepair).toMatch(/set region_code = b\.code,\s+region_name = b\.name/);
    for (const t of ['venues', 'events', 'hotels', 'organizations']) {
      // keyed on the city's own code, not on the 38-row temp table
      expect(bdRepair).toMatch(new RegExp(`update public\\.${t} \\w set state = s\\.name[\\s\\S]*?public\\.resolve_region_code\\('BD', btrim\\(\\w\\.state\\)\\) = c\\.region_code;`));
    }
    expect(verify).toMatch(/entity_numeric_state_resolvable'\)::int, -1\) <> 0/);
  });
});

describe('AR fips swap', () => {
  it('swaps the vocabulary back to GeoNames, in migration and generator', () => {
    expect(statements).toMatch(/set fips_code = '01'\s+where code = 'AR-B'/);
    expect(statements).toMatch(/set fips_code = '07'\s+where code = 'AR-C'/);
    expect(generator).toMatch(/FIPS_OVERRIDES = \{\s*'AR-B': '01', 'AR-C': '07',/);
    expect(generator).toMatch(/q\(FIPS_OVERRIDES\[s\.iso3166_2\] \?\? s\.fips_code\)/);
  });
  it('repairs only rows whose recorded GeoNames number proves the swap', () => {
    expect(arRepair).toMatch(/r\.before ->> 'region_name' in \('01', '07'\)/);
    expect(arRepair).toMatch(/ev\.num = '01' and c\.region_code = 'AR-C' and c\.region_name = 'Autonomous City of Buenos Aires'/);
    expect(arRepair).toMatch(/ev\.num = '07' and c\.region_code = 'AR-B' and c\.region_name = 'Buenos Aires'/);
  });
  it('refuses a repair that would collide with a same-name twin', () => {
    expect(arRepair).toMatch(/and not exists \(\s*select 1 from public\.cities o/);
  });
  it('fixes entity state only on the province towns, only the wrong value', () => {
    for (const t of ['venues', 'events', 'hotels', 'organizations']) {
      expect(arRepair).toMatch(new RegExp(`update public\\.${t} \\w set state = 'Buenos Aires'[\\s\\S]*?s\\.code = 'AR-B' and \\w\\.state = 'Autonomous City of Buenos Aires';`));
    }
  });
});

describe('privileges and wiring', () => {
  it('revokes runner, lookup and sentinel from anon/authenticated', () => {
    for (const sig of [
      'city_region_polygon_lookup\\(text, geometry\\)',
      'geo_boundary_region\\(bigint, text\\)',
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
