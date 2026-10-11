import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// Write-time guard against linking a venue, hotel or organization to a
// same-name city abroad.
// See supabase/migrations/99991791728180_venue_city_country_guard.sql.
const MIGRATION = '99991791728180_venue_city_country_guard.sql';
const raw = readFileSync(join(process.cwd(), 'supabase/migrations', MIGRATION), 'utf8');
// Comment-stripped: the header quotes the rules it describes.
const sql = raw
  .split('\n')
  .filter((l) => !l.trim().startsWith('--'))
  .join('\n');
const fnBody = sql.slice(sql.indexOf('create or replace function public.entity_city_country_guard'), sql.indexOf('$fn$;'));

describe('venue city/country guard', () => {
  it('protects hotels and organizations too, ahead of tg_city_country_derivation', () => {
    // tg_city_country_derivation overwrites country_id unconditionally, so the
    // guard must sort before it on both tables.
    expect('hotel_aa_city_country_guard' < 'hotel_city_country_derivation').toBe(true);
    expect('organization_aa_city_country_guard' < 'organization_city_country_derivation').toBe(true);
    expect(sql).toMatch(/create trigger hotel_aa_city_country_guard\s+before insert or update of city_id, country_id, latitude, longitude on public\.hotels\s+for each row execute function public\.entity_city_country_guard\(\)/);
    expect(sql).toMatch(/create trigger organization_aa_city_country_guard\s+before insert or update of city_id, country_id, latitude, longitude on public\.organizations\s+for each row execute function public\.entity_city_country_guard\(\)/);
    expect(sql).toMatch(/P4 failed: hotel kept the foreign city or lost VE/);
    expect(sql).toMatch(/P5 failed: organization kept the foreign city or lost VE/);
  });

  it('sorts before trg_venues_geo_derive, so a refused city cannot drag its country', () => {
    expect('trg_venues_city_country_guard' < 'trg_venues_geo_derive').toBe(true);
    expect(sql).toMatch(/create trigger trg_venues_city_country_guard\s+before insert or update of city_id, country_id, latitude, longitude on public\.venues/);
  });

  it('casts coordinates, because hotels store them as double precision', () => {
    // haversine_m / geo_country_at take numeric only; an uncast call raises
    // 42883 on every hotel write.
    expect(fnBody).not.toMatch(/haversine_m\(new\.latitude,/);
    expect(fnBody).not.toMatch(/geo_country_at\(new\.latitude,/);
    expect(fnBody.match(/new\.latitude::numeric, new\.longitude::numeric/g)?.length).toBe(3);
  });

  it('only runs the polygon test past the 100 km prefilter', () => {
    expect(fnBody).toMatch(/if v_km > 100 then/);
    const prefilter = fnBody.indexOf('if v_km > 100 then');
    expect(fnBody.indexOf('geo_country_at')).toBeGreaterThan(prefilter);
  });

  it('keeps border towns linkable (25 km outside the city country polygon)', () => {
    expect(fnBody).toMatch(/v_m_outside is null or v_m_outside >= 25000/);
  });

  it('allows a far city in the same country or its sovereign', () => {
    expect(fnBody).toMatch(/not public\.geo_countries_equivalent\(v_city_cc, v_pt_iso\)/);
  });

  it('refuses the city and records why, but never rewrites country_id', () => {
    expect(fnBody).toMatch(/new\.city_id := null;/);
    expect(fnBody).toMatch(/'city_guard'/);
    expect(fnBody).not.toMatch(/new\.country_id\s*:=/);
    expect(fnBody).not.toMatch(/needs_attention/);
  });

  it('verifies behaviour, and a missing probe row fails instead of skipping', () => {
    expect(sql).toMatch(/P1 failed: foreign same-name city was accepted/);
    expect(sql).toMatch(/P3 failed: a same-country far city was refused/);
    expect(sql).not.toMatch(/raise notice 'guard behaviour check skipped/);
  });
});
