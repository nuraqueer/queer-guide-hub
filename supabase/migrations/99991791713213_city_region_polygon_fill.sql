-- cities.region_code from the admin-1 polygons already in the database.
--
-- WHY
-- 99991790994947 / 99991791059373 derived region_code from the free-text
-- region_name and named the remaining gap: "needs a geocoder or Wikidata P131".
-- Measured 2026-10-11 the gap is 6,657 of 15,738 live cities (ES 1,012,
-- DE 766, US 468, IT 376, FR 331, BR 330, MX 291, NL 280, PT 277 of 288,
-- CH 237 ...), 6,410 of them with coordinates. No geocoder is needed:
-- geo_boundaries already holds 4,596 Natural Earth admin-1 polygons, every
-- one carrying an ISO 3166-2 code.
--
-- MEASURED BEFORE WRITING (prod, read-only)
-- * Point-in-polygon alone agrees with the stored region_code on only 64% of
--   the 8,448 cities that have both. That is NOT noise: Natural Earth's
--   "admin1" is a department/province/county in FR, ES, GB, IT, BE (1,152 /
--   593 / 435 / 236 / 154 rows), whose ISO parent IS the stored code.
--   Climbing geo_subdivision_root() to the first level: 8,048 of 8,199 agree
--   (98.2%).
-- * The disagreement is not spread evenly — it is per COUNTRY and structural:
--   AR 69% (NE and our data disagree on AR-B/AR-C, Buenos Aires province vs
--   the autonomous city), MA 20% and IR 0% (NE carries the pre-reform region
--   numbering), RS 17% (districts with no parent in the vocabulary), plus
--   capital districts (Conakry, Abidjan, Asmara, Bogotá inside Cundinamarca).
--   A global fill would write those wrong codes confidently. So each run
--   CALIBRATES per country against cities that already carry a code and only
--   fills a country that agrees >= 95% over >= 5 calibration rows.
--   Trusted at the time of writing: ES 99.7, DE 99.4, US 99.6, BR 99.7,
--   FR 98.9, MX 99.5, NL 98.8, IT 98.7, CH 97.8, AT 96.6, BE/CA/GB/CL/AU 100.
-- * The rest of the disagreement in trusted countries is border cities
--   (Birsfelden/Muttenz on the Basel-Stadt line, Klosterneuburg on Vienna,
--   Carter Lake, Cincinnati) where NE's generalised polygons and our city
--   coordinates are each a few hundred metres off. A point with another
--   admin-1 polygon of a DIFFERENT first-level unit within ~3 km is stamped
--   ambiguous_border and left alone.
-- * Dry run of this file on prod (rolled back): 5,037 filled, 0 wrong
--   country; AR 54 re-filed (47 -> AR-B, 7 -> AR-C) and then trusted (83
--   filled); IR trusted after the crosswalk.
--
-- VOCABULARY FIXES (found by the calibration, carried by the generator too)
-- * FR-70 Haute-Saône hangs under FR-GES (Grand Est). It is
--   Bourgogne-Franche-Comté, as every sibling department (21, 25, 39, 58, 71,
--   89, 90) already is. Vesoul and Lavoncourt disagreed on exactly this.
-- * FR-75C Paris (the collectivity) has no parent, so a point in Paris rolled
--   up to FR-75C while every Paris city on record carries FR-IDF. 0 live
--   cities carry FR-75C (measured), so giving it parent FR-IDF moves nothing.
--
-- CROSSWALK — the three countries whose polygons speak another code scheme
-- (measured per polygon and per province centroid, 2026-10-11):
-- * AR: polygon and vocabulary codes are IDENTICAL; what was wrong is OURS.
--   dr5hn gives AR-B (the province) fips "07" and AR-C (the autonomous city)
--   fips "01"; GeoNames admin1 is the other way round (AR.01 = Buenos Aires
--   province, AR.07 = Ciudad de Buenos Aires). So every city whose region_name
--   arrived as the GeoNames number was filed in the wrong one: 47 province
--   towns (Bahía Blanca, Azul, Junín, Mar del Plata ...) under the capital and
--   the capital itself plus Palermo, Belgrano, Balvanera ... under the
--   province. content_revisions still holds the original "01"/"07" for each,
--   so the repair keys on that evidence, not on the polygon.
-- * IR: Natural Earth numbers the provinces differently (its IR-07 is two
--   polygons, Tehran AND Alborz; ours is Fars). 31 rows map polygon NAME to
--   our code, 1:1, all 31 provinces covered.
-- * MA: Natural Earth has the 16 regions from BEFORE the 2015 reform, we have
--   the 12 after it. Placing each of our provinces' centroids in the old
--   polygons: 7 old regions lie wholly inside one new region and are mapped;
--   7 were split by the reform and map to NOTHING (a point there is stamped
--   no_code rather than guessed); MA-15/MA-16 are Western Sahara and are
--   deliberately not given a Moroccan region.
-- * Two dr5hn parents found on the way: MA-NOU Nouaceur hangs under
--   Rabat-Salé-Kénitra, it is Casablanca-Settat; MA-CHT Chtouka-Aït Baha hangs
--   under Casablanca-Settat, it is Souss-Massa. Carried by the generator too.
--
-- RULES
-- * Fill-if-empty only: region_code IS NULL and region_name empty. An existing
--   code is never overwritten BY A POLYGON — a generalised polygon is the
--   weaker signal. The one overwrite in this file is the AR repair, and it
--   rests on the recorded GeoNames number, not on the polygon.
--   The 256 cities with an unresolvable region_name text are left out too.
-- * region_name is written only when the subdivision's own name resolves back
--   to the same code (40 first-level names are ambiguous and do not); else
--   only region_code is written, because a later region_name write would
--   re-derive and NULL it.
-- * Both columns go in one UPDATE: cities_sync_region_code() keeps an
--   explicitly changed region_code.
-- * Visit-once: every outcome is stamped enrichment_status.region_polygon with
--   `||` (never a whole-object write-back — 99991791569736). Delete the key to
--   retry a row, e.g. after a country's calibration improves.
-- * A same-name city already coded with the polygon's region is a DUPLICATE,
--   not a fill: the first dry run aborted on cities_country_canonical_key_uniq
--   (Bielsko-Biała, PL-24). Stamped twin_exists / twin_in_batch with the twin's
--   id — a dedup signal for a human, never a merge here.
-- * Batch <= 300 (city UPDATEs fan out through trg_sync_geo_spine).
-- * PostGIS lives in the `extensions` schema here, so the two functions that
--   call st_* carry it on their search_path (the first dry run failed 42883).

-- 1. Vocabulary
update public.geo_subdivisions set parent_code = 'FR-BFC'
 where code = 'FR-70' and parent_code is distinct from 'FR-BFC';
update public.geo_subdivisions set parent_code = 'FR-IDF'
 where code = 'FR-75C' and parent_code is distinct from 'FR-IDF';
update public.geo_subdivisions set parent_code = 'MA-06'
 where code = 'MA-NOU' and parent_code is distinct from 'MA-06';
update public.geo_subdivisions set parent_code = 'MA-09'
 where code = 'MA-CHT' and parent_code is distinct from 'MA-09';
update public.geo_subdivisions set fips_code = '01'
 where code = 'AR-B' and fips_code is distinct from '01';
update public.geo_subdivisions set fips_code = '07'
 where code = 'AR-C' and fips_code is distinct from '07';

-- 1b. Crosswalk for polygons whose code is not ours. region_code NULL means
--     "this polygon has no single answer" and the runner stamps no_code.
create table if not exists public.geo_boundary_region_map (
  polygon_code text not null,
  polygon_name text not null,
  region_code  text references public.geo_subdivisions (code),
  reason       text not null,
  primary key (polygon_code, polygon_name)
);
alter table public.geo_boundary_region_map enable row level security;
revoke all on public.geo_boundary_region_map from public, anon, authenticated;
grant select on public.geo_boundary_region_map to service_role;

insert into public.geo_boundary_region_map (polygon_code, polygon_name, region_code, reason) values
  ('IR-01', 'East Azarbaijan', 'IR-03', 'ne_renumbered'),
  ('IR-02', 'West Azarbaijan', 'IR-04', 'ne_renumbered'),
  ('IR-03', 'Ardebil', 'IR-24', 'ne_renumbered'),
  ('IR-04', 'Esfahan', 'IR-10', 'ne_renumbered'),
  ('IR-05', 'Ilam', 'IR-16', 'ne_renumbered'),
  ('IR-06', 'Bushehr', 'IR-18', 'ne_renumbered'),
  ('IR-07', 'Alborz', 'IR-30', 'ne_renumbered'),
  ('IR-07', 'Tehran', 'IR-23', 'ne_renumbered'),
  ('IR-08', 'Chahar Mahall and Bakhtiari', 'IR-14', 'ne_renumbered'),
  ('IR-10', 'Khuzestan', 'IR-06', 'ne_renumbered'),
  ('IR-11', 'Zanjan', 'IR-19', 'ne_renumbered'),
  ('IR-12', 'Semnan', 'IR-20', 'ne_renumbered'),
  ('IR-13', 'Sistan and Baluchestan', 'IR-11', 'ne_renumbered'),
  ('IR-14', 'Fars', 'IR-07', 'ne_renumbered'),
  ('IR-15', 'Kerman', 'IR-08', 'ne_renumbered'),
  ('IR-16', 'Kordestan', 'IR-12', 'ne_renumbered'),
  ('IR-17', 'Kermanshah', 'IR-05', 'ne_renumbered'),
  ('IR-18', 'Kohgiluyeh and Buyer Ahmad', 'IR-17', 'ne_renumbered'),
  ('IR-19', 'Gilan', 'IR-01', 'ne_renumbered'),
  ('IR-20', 'Lorestan', 'IR-15', 'ne_renumbered'),
  ('IR-21', 'Mazandaran', 'IR-02', 'ne_renumbered'),
  ('IR-22', 'Markazi', 'IR-00', 'ne_renumbered'),
  ('IR-23', 'Hormozgan', 'IR-22', 'ne_renumbered'),
  ('IR-24', 'Hamadan', 'IR-13', 'ne_renumbered'),
  ('IR-25', 'Yazd', 'IR-21', 'ne_renumbered'),
  ('IR-26', 'Qom', 'IR-25', 'ne_renumbered'),
  ('IR-27', 'Golestan', 'IR-27', 'ne_renumbered'),
  ('IR-28', 'Qazvin', 'IR-26', 'ne_renumbered'),
  ('IR-29', 'South Khorasan', 'IR-29', 'ne_renumbered'),
  ('IR-30', 'Razavi Khorasan', 'IR-09', 'ne_renumbered'),
  ('IR-31', 'North Khorasan', 'IR-28', 'ne_renumbered'),
  ('MA-01', 'Tanger - Tétouan', 'MA-01', 'pre_2015_region_within'),
  ('MA-04', 'Oriental', 'MA-02', 'pre_2015_region_within'),
  ('MA-05', 'Fès - Boulemane', 'MA-03', 'pre_2015_region_within'),
  ('MA-07', 'Rabat - Salé - Zemmour - Zaer', 'MA-04', 'pre_2015_region_within'),
  ('MA-08', 'Grand Casablanca', 'MA-06', 'pre_2015_region_within'),
  ('MA-11', 'Marrakech - Tensift - Al Haouz', 'MA-07', 'pre_2015_region_within'),
  ('MA-12', 'Tadla - Azilal', 'MA-05', 'pre_2015_region_within'),
  ('MA-02', 'Gharb - Chrarda - Béni Hssen', null, 'pre_2015_region_split'),
  ('MA-03', 'Taza - Al Hoceima - Taounate', null, 'pre_2015_region_split'),
  ('MA-06', 'Meknès - Tafilalet', null, 'pre_2015_region_split'),
  ('MA-09', 'Chaouia - Ouardigha', null, 'pre_2015_region_split'),
  ('MA-10', 'Doukkala - Abda', null, 'pre_2015_region_split'),
  ('MA-13', 'Souss - Massa - Draâ', null, 'pre_2015_region_split'),
  ('MA-14', 'Guelmim - Es-Semara', null, 'pre_2015_region_split'),
  ('MA-15', 'Laâyoune - Boujdour - Sakia El Hamra', null, 'disputed_western_sahara'),
  ('MA-16', 'Oued el Dahab', null, 'disputed_western_sahara')
on conflict (polygon_code, polygon_name) do update
  set region_code = excluded.region_code, reason = excluded.reason;

-- 1c. AR: re-file the cities the swapped fips put in the wrong unit. Keyed on
--     the GeoNames number content_revisions recorded as their region_name,
--     and only while region_name still reads what the writeback put there.
create temp table _ar_swap on commit drop as
select c.id,
       c.region_code as was,
       ev.num,
       case ev.num when '01' then 'AR-B' else 'AR-C' end as code,
       case ev.num when '01' then 'Buenos Aires' else 'Autonomous City of Buenos Aires' end as name
  from public.cities c
  join public.countries co on co.id = c.country_id and co.code = 'AR'
  cross join lateral (
    select r.before ->> 'region_name' as num
      from public.content_revisions r
     where r.source_table = 'cities' and r.source_id = c.id
       and r.before ->> 'region_name' in ('01', '07')
     order by r.seq desc
     limit 1
  ) ev
 where (ev.num = '01' and c.region_code = 'AR-C' and c.region_name = 'Autonomous City of Buenos Aires')
    or (ev.num = '07' and c.region_code = 'AR-B' and c.region_name = 'Buenos Aires');

update public.cities c
   set region_code = s.code,
       region_name = s.name,
       enrichment_status = coalesce(c.enrichment_status, '{}'::jsonb)
         || jsonb_build_object('region_fips_swap_repair', jsonb_build_object(
              'from', s.was, 'to', s.code, 'geonames_admin1', s.num, 'at', now()))
  from _ar_swap s
 where c.id = s.id
   and not exists (
     select 1 from public.cities o
      where o.country_id = c.country_id and o.id <> c.id and o.region_code = s.code
        and (lower(o.name) = lower(c.name) or o.canonical_key = c.canonical_key));

-- The province towns' venues/events copied the wrong name into `state`.
update public.venues v set state = 'Buenos Aires'
  from _ar_swap s where v.city_id = s.id and s.code = 'AR-B' and v.state = 'Autonomous City of Buenos Aires';
update public.events e set state = 'Buenos Aires'
  from _ar_swap s where e.city_id = s.id and s.code = 'AR-B' and e.state = 'Autonomous City of Buenos Aires';
update public.hotels h set state = 'Buenos Aires'
  from _ar_swap s where h.city_id = s.id and s.code = 'AR-B' and h.state = 'Autonomous City of Buenos Aires';
update public.organizations o set state = 'Buenos Aires'
  from _ar_swap s where o.city_id = s.id and s.code = 'AR-B' and o.state = 'Autonomous City of Buenos Aires';

-- 2. Which first-level unit a polygon stands for, in a given country: the
--    crosswalk wins when it has a row (even a NULL one), else our own code or
--    its name. Used for the point's own polygon AND for its neighbours.
create or replace function public.geo_boundary_region(p_boundary_id bigint, p_cc text)
returns text
language sql
stable
set search_path to 'public'
as $$
  select case when split_part(g.iso_3166_2, '-', 1) = p_cc then
           case when m.polygon_code is not null then m.region_code
                else coalesce(public.geo_subdivision_root(g.iso_3166_2),
                              public.resolve_region_code(p_cc, g.name))
           end
         end
    from public.geo_boundaries g
    left join public.geo_boundary_region_map m
      on m.polygon_code = g.iso_3166_2 and m.polygon_name = g.name
   where g.id = p_boundary_id;
$$;

revoke all on function public.geo_boundary_region(bigint, text) from public, anon, authenticated;
grant execute on function public.geo_boundary_region(bigint, text) to service_role;

create or replace function public.city_region_polygon_lookup(
  p_cc text,
  p_pt geometry,
  out boundary_id bigint,
  out polygon_code text,
  out polygon_country text,
  out region_code text
)
language sql
stable
set search_path to 'public', 'extensions'
as $$
  select g.id,
         g.iso_3166_2,
         split_part(g.iso_3166_2, '-', 1),
         public.geo_boundary_region(g.id, p_cc)
    from public.geo_boundaries g
   where g.boundary_kind = 'admin1'
     and st_intersects(g.geom, p_pt)
   order by g.id
   limit 1;
$$;

revoke all on function public.city_region_polygon_lookup(text, geometry) from public, anon, authenticated;
grant execute on function public.city_region_polygon_lookup(text, geometry) to service_role;

-- 3. Runner
create or replace function public.run_city_region_polygon_fill(
  p_batch integer default 300,
  p_dry_run boolean default false
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $fn$
declare
  v_batch int := least(greatest(coalesce(p_batch, 300), 1), 300);
  v_examined int;
  v_written int := 0;
  v_summary jsonb;
begin
  drop table if exists _rpf_cand;
  create temp table _rpf_cand on commit drop as
  select c.id,
         c.country_id,
         co.code as cc,
         lower(c.name) as lname,
         c.canonical_key as ckey,
         c.name_normalized as nnorm,
         st_setsrid(st_makepoint(c.longitude::float8, c.latitude::float8), 4326) as pt
    from public.cities c
    join public.countries co on co.id = c.country_id
   where c.duplicate_of_id is null
     and c.region_code is null
     and nullif(btrim(c.region_name), '') is null
     and c.latitude is not null
     and c.longitude is not null
     and not (coalesce(c.enrichment_status, '{}'::jsonb) ? 'region_polygon')
   order by co.code, c.id
   limit v_batch;

  select count(*) into v_examined from _rpf_cand;
  if v_examined = 0 then
    return jsonb_build_object('examined', 0, 'written', 0, 'dry_run', p_dry_run, 'by_state', '{}'::jsonb);
  end if;

  -- Per-country calibration against cities that already carry a code. Capped
  -- at 200 rows per country so a batch costs the same in the US as in Malta.
  drop table if exists _rpf_trust;
  create temp table _rpf_trust on commit drop as
  with cal as (
    select x.cc, x.region_code, x.pt
      from (
        select co.code as cc,
               c.region_code,
               st_setsrid(st_makepoint(c.longitude::float8, c.latitude::float8), 4326) as pt,
               row_number() over (partition by co.code order by c.id) as rn
          from public.cities c
          join public.countries co on co.id = c.country_id
         where c.duplicate_of_id is null
           and c.region_code is not null
           and c.latitude is not null
           and c.longitude is not null
           and co.code in (select distinct cc from _rpf_cand)
      ) x
     where x.rn <= 200
  ), hit as (
    select cal.cc, cal.region_code, l.region_code as top
      from cal
      left join lateral public.city_region_polygon_lookup(cal.cc, cal.pt) l on true
  )
  select cc,
         count(*) filter (where top is not null) as n,
         count(*) filter (where top = region_code) as agree
    from hit
   group by cc;

  drop table if exists _rpf_res;
  create temp table _rpf_res on commit drop as
  select k.id,
         k.cc,
         k.lname,
         k.ckey,
         k.nnorm,
         l.polygon_code,
         l.region_code as top,
         s.name as sub_name,
         tw.id as twin_id,
         case
           when l.boundary_id is null then 'no_polygon'
           when l.polygon_country <> k.cc then 'other_country'
           when s.code is null then 'no_code'
           when coalesce(t.n, 0) < 5 or t.agree::numeric / t.n < 0.95 then 'country_untrusted'
           -- ~3 km (0.03 degrees; narrower east-west at high latitude).
           when exists (
             select 1
               from public.geo_boundaries o
              where o.boundary_kind = 'admin1'
                and o.id <> l.boundary_id
                and st_dwithin(o.geom, k.pt, 0.03)
                and coalesce(public.geo_boundary_region(o.id, k.cc), o.iso_3166_2)
                    is distinct from l.region_code
           ) then 'ambiguous_border'
           when tw.id is not null then 'twin_exists'
           else 'filled'
         end as state
    from _rpf_cand k
    left join lateral public.city_region_polygon_lookup(k.cc, k.pt) l on true
    left join public.geo_subdivisions s
      on s.code = l.region_code
     and s.country_code = k.cc
     and s.parent_code is null
    left join _rpf_trust t on t.cc = k.cc
    -- A same-name city already coded with this region: the uncoded row is its
    -- duplicate, and writing the code would violate the (country, region_code,
    -- name) unique keys — two of which also count merged rows.
    left join lateral (
      select o.id
        from public.cities o
       where o.country_id = k.country_id
         and o.id <> k.id
         and o.region_code = l.region_code
         and (lower(o.name) = k.lname
              or o.canonical_key = k.ckey
              or (o.duplicate_of_id is null and o.name_normalized = k.nnorm))
       order by (o.duplicate_of_id is null) desc, o.id
       limit 1
    ) tw on true;

  -- Two uncoded same-name rows in one batch landing in the same region: only
  -- the first is filled, the rest are its duplicates.
  update _rpf_res r
     set state = 'twin_in_batch',
         twin_id = (select min(r2.id::text)::uuid from _rpf_res r2
                     where r2.state = 'filled' and r2.cc = r.cc and r2.top = r.top and r2.id < r.id
                       and (r2.lname = r.lname or r2.ckey = r.ckey or r2.nnorm = r.nnorm))
   where r.state = 'filled'
     and exists (select 1 from _rpf_res r2
                  where r2.state = 'filled' and r2.cc = r.cc and r2.top = r.top and r2.id < r.id
                    and (r2.lname = r.lname or r2.ckey = r.ckey or r2.nnorm = r.nnorm));

  if not p_dry_run then
    update public.cities c
       set region_code = case when r.state = 'filled' then r.top else c.region_code end,
           region_name = case
                           when r.state = 'filled'
                            and public.resolve_region_code(r.cc, r.sub_name) = r.top
                           then r.sub_name
                           else c.region_name
                         end,
           enrichment_status = coalesce(c.enrichment_status, '{}'::jsonb)
             || jsonb_build_object('region_polygon', jsonb_build_object(
                  'state', r.state,
                  'at', now(),
                  'source', 'natural_earth_admin1',
                  'polygon_code', r.polygon_code,
                  'region_code', case when r.state = 'filled' then r.top end,
                  'twin_id', r.twin_id,
                  'by', 'run_city_region_polygon_fill'))
      from _rpf_res r
     where c.id = r.id
       and c.region_code is null
       and nullif(btrim(c.region_name), '') is null;
    get diagnostics v_written = row_count;
  end if;

  select jsonb_build_object(
           'examined', v_examined,
           'written', v_written,
           'dry_run', p_dry_run,
           'by_state', coalesce((select jsonb_object_agg(state, n)
                                   from (select state, count(*) n from _rpf_res group by state) s), '{}'::jsonb),
           'filled_by_country', coalesce((select jsonb_object_agg(cc, n)
                                            from (select cc, count(*) n from _rpf_res where state = 'filled' group by cc) s), '{}'::jsonb),
           'untrusted_countries', coalesce((select jsonb_object_agg(t.cc, jsonb_build_object('n', t.n, 'agree', t.agree))
                                              from _rpf_trust t
                                             where coalesce(t.n, 0) < 5 or t.agree::numeric / t.n < 0.95), '{}'::jsonb)
         )
    into v_summary;
  return v_summary;
end;
$fn$;

revoke all on function public.run_city_region_polygon_fill(integer, boolean) from public, anon, authenticated;
grant execute on function public.run_city_region_polygon_fill(integer, boolean) to service_role;

-- 4. Sentinel (service_role only; health script warns, fails only on a
--    broken probe or a filled code from the wrong country)
create or replace function public.city_region_polygon_signals()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with live as (
    select c.id, c.region_code, c.region_name, c.latitude, c.enrichment_status, co.code as cc
      from public.cities c
      join public.countries co on co.id = c.country_id
     where c.duplicate_of_id is null
  )
  select jsonb_build_object(
    'probe_ok', true,
    'cities_live', (select count(*) from live),
    'admin1_polygons', (select count(*) from public.geo_boundaries where boundary_kind = 'admin1'),
    'unvisited_with_coords', (
      select count(*) from live
       where region_code is null and nullif(btrim(region_name), '') is null
         and latitude is not null
         and not (coalesce(enrichment_status, '{}'::jsonb) ? 'region_polygon')),
    'stamped_by_state', coalesce((
      select jsonb_object_agg(st, n) from (
        select enrichment_status -> 'region_polygon' ->> 'state' as st, count(*) n
          from live where enrichment_status ? 'region_polygon' group by 1) s), '{}'::jsonb),
    -- zero-invariant
    'filled_wrong_country', (
      select count(*) from live
       where enrichment_status -> 'region_polygon' ->> 'state' = 'filled'
         and split_part(region_code, '-', 1) <> cc)
  );
$$;

revoke all on function public.city_region_polygon_signals() from public, anon, authenticated;
grant execute on function public.city_region_polygon_signals() to service_role;

-- 5. Registry + cron (pure SQL, family C). Every 15 min drains the ~6k
--    backlog in about a day; once drained a run examines 0 rows and exits.
insert into public.admin_automations (slug, name, description, managed_by, enabled, "trigger", schedule, action)
values (
  'city_region_polygon_fill',
  'city_region_polygon_fill',
  'Fills cities.region_code (and region_name when unambiguous) from Natural Earth admin-1 polygons, rolled up to the ISO first-level unit. Only countries whose existing codes agree >= 95% with the polygons are filled; border points within ~3 km of another unit are skipped. Fill-if-empty, visit-once (enrichment_status.region_polygon).',
  'system',
  true,
  jsonb_build_object('type', 'schedule'),
  '7-59/15 * * * *',
  jsonb_build_object(
    'type', 'cron',
    'jobname', 'city_region_polygon_fill',
    'command', 'select public.run_city_region_polygon_fill(300)'
  )
)
on conflict (slug) do update
  set schedule = excluded.schedule,
      action   = excluded.action,
      enabled  = true;

select cron.schedule(
  'city_region_polygon_fill',
  '7-59/15 * * * *',
  public.admin_automation_effective_command(
    'city_region_polygon_fill',
    (select action ->> 'command' from public.admin_automations where slug = 'city_region_polygon_fill')))
where not exists (select 1 from cron.job where jobname = 'city_region_polygon_fill');

-- 6. Postconditions
do $verify$
declare
  v_res jsonb;
begin
  if (select parent_code from public.geo_subdivisions where code = 'FR-70') is distinct from 'FR-BFC' then
    raise exception 'P1 failed: FR-70 is not under FR-BFC';
  end if;
  if public.geo_subdivision_root('FR-75C') is distinct from 'FR-IDF' then
    raise exception 'P2 failed: FR-75C does not roll up to FR-IDF';
  end if;
  if (select fips_code from public.geo_subdivisions where code = 'AR-B') is distinct from '01'
     or (select fips_code from public.geo_subdivisions where code = 'AR-C') is distinct from '07' then
    raise exception 'P2b failed: AR fips not swapped back to GeoNames';
  end if;
  if public.geo_subdivision_root('MA-NOU') is distinct from 'MA-06'
     or public.geo_subdivision_root('MA-CHT') is distinct from 'MA-09' then
    raise exception 'P2c failed: MA province parents not repaired';
  end if;
  -- Every IR province is reached by exactly one crosswalk row, and every
  -- mapped polygon lies within 50 km of its province's own centroid. Not
  -- "contains": NE's Razavi/South Khorasan line predates the county moves
  -- since 2013, so South Khorasan's centroid sits 22 km outside its polygon.
  -- A wrong mapping is hundreds of km off.
  if (select count(distinct region_code) from public.geo_boundary_region_map where polygon_code like 'IR-%')
     <> (select count(*) from public.geo_subdivisions where country_code = 'IR' and parent_code is null) then
    raise exception 'P2d failed: IR crosswalk does not cover every province exactly once';
  end if;
  if exists (
    select 1
      from public.geo_boundary_region_map m
      join public.geo_boundaries g on g.boundary_kind = 'admin1' and g.iso_3166_2 = m.polygon_code and g.name = m.polygon_name
      join public.geo_subdivisions s on s.code = m.region_code
     where m.polygon_code like 'IR-%' and s.latitude is not null
       and not extensions.st_dwithin(g.geom::extensions.geography,
             extensions.st_setsrid(extensions.st_makepoint(s.longitude::float8, s.latitude::float8), 4326)::extensions.geography, 50000)
  ) then
    raise exception 'P2e failed: an IR crosswalk row points at a province whose centroid is over 50 km from that polygon';
  end if;
  if exists (
    select 1 from public.geo_boundary_region_map m
     where not exists (select 1 from public.geo_boundaries g
                        where g.boundary_kind = 'admin1' and g.iso_3166_2 = m.polygon_code and g.name = m.polygon_name)
  ) then
    raise exception 'P2f failed: a crosswalk row names a polygon that does not exist';
  end if;
  if exists (
    select 1 from public.cities c
     where c.enrichment_status ? 'region_fips_swap_repair'
       and c.region_code is distinct from c.enrichment_status -> 'region_fips_swap_repair' ->> 'to'
  ) then
    raise exception 'P2g failed: an AR repair did not stick';
  end if;
  if exists (select 1 from public.geo_subdivisions where public.geo_subdivision_root(code) is null) then
    raise exception 'P3 failed: a subdivision climbs to no root after the parent fixes';
  end if;
  -- The runner must execute and report, without writing, in this transaction.
  v_res := public.run_city_region_polygon_fill(50, true);
  if v_res is null or (v_res ->> 'written')::int <> 0 or not (v_res ? 'by_state') then
    raise exception 'P4 failed: dry run wrote or returned no summary: %', v_res;
  end if;
  if has_function_privilege('anon', 'public.run_city_region_polygon_fill(integer, boolean)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.run_city_region_polygon_fill(integer, boolean)', 'EXECUTE')
     or has_function_privilege('anon', 'public.city_region_polygon_signals()', 'EXECUTE')
     or has_table_privilege('anon', 'public.geo_boundary_region_map', 'SELECT') then
    raise exception 'P5 failed: runner or sentinel reachable by anon/authenticated';
  end if;
  if not exists (select 1 from cron.job where jobname = 'city_region_polygon_fill') then
    raise exception 'P6 failed: cron job not scheduled';
  end if;
end
$verify$;
