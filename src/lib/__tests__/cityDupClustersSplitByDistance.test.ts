import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * The city exact-duplicate finder grouped by (name, country) only, so Portland
 * OR / Portland ME and 16 other same-name, different-state pairs were offered
 * as duplicates and merged on 2026-10-10. It now splits a name group by
 * distance (50 km). Asserted over COMMENT-STRIPPED SQL: the header quotes the
 * rule in prose.
 */

const MIGRATION = '99991791721662_city_dup_clusters_split_by_distance.sql';

const sql = readFileSync(join(process.cwd(), 'supabase', 'migrations', MIGRATION), 'utf8')
  .split('\n')
  .map((l) => l.replace(/--.*$/, ''))
  .join('\n');

const body = sql.slice(sql.indexOf('create or replace function'), sql.indexOf('$function$;'));
const verify = sql.slice(sql.indexOf('$verify$'));

describe('city duplicate clusters split by distance', () => {
  it('groups by an anchor, not by name and country alone', () => {
    expect(body).toMatch(/group by nt, nc, nco, anchor/);
  });

  it('anchors only within 50 km', () => {
    expect(body).toMatch(/haversine_m\(n\.lat, n\.lng, a\.lat, a\.lng\) <= 50000(?!\d)/);
  });

  it('keeps coordinate-less rows visible rather than hiding them', () => {
    expect(body).toMatch(/n\.lat is null or a\.lat is null/);
    expect(body).toContain("'has_coords'");
  });

  it('exposes the region to the reviewer', () => {
    expect(body).toContain("'region', region_name");
  });

  it('leaves non-city types on the old single-anchor grouping', () => {
    expect(body).toMatch(/case when p_content_type <> 'city' then ''/);
  });

  it('anchors only names that repeat (the full-corpus scan took ~50 s)', () => {
    expect(body).toMatch(/having count\(\*\) > 1\) k/);
    expect(body).toMatch(/from cand a/);
  });

  it('postcondition raises on any cluster pair over 50 km', () => {
    expect(verify).toMatch(/> 50000;\s+if v_bad <> 0 then\s+raise exception/);
  });
});
