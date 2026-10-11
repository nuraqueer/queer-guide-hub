-- The city "exact duplicates" view offered DIFFERENT places as duplicates, and
-- 17 of them were merged.
--
-- WHAT HAPPENED (measured on prod, 2026-10-11)
--   _find_duplicate_clusters_body('city') grouped search_documents by
--   (normalized name, country) only. cities holds one row per US state for a
--   shared name, so Portland OR / Portland ME, Charleston IL / SC / WV,
--   Hollywood CA / FL, Columbia MO / SC, Wilmington DE / NC ... all came out as
--   "exact duplicates". The member line showed title + slug only, so nothing on
--   screen told them apart. On 2026-10-10 an admin merged 17 such pairs
--   (134 km to 4,082 km apart); Portland ME's venues and events moved to
--   Oregon. All 17 were unmerged 2026-10-11 via unmerge_cities (schema:1,
--   reparenting restored).
--   The removed comment claimed "a surviving same-name-same-country pair is a
--   real duplicate" because uk_cities_country_name_active forbids the same name
--   twice in one country. That is false: the split-name trigger keeps the
--   region out of the key only for NEW rows, and the corpus holds these pairs.
--
-- WHY DISTANCE AND NOT region_name
--   Measured over the 452 standing city merges: region_name DIFFERS on 27
--   pairs that are the same place ("Tirana"/"Central Albania", "VLG"/"West
--   Flanders", FIPS codes "08"/"07") and is NULL on 363. Grouping by it would
--   split real duplicates. Coordinates separate the wrong merges cleanly: every
--   one of the 17 sits 134+ km apart, every legitimate pair checked sits under
--   25 km. 50 km is the bound.
--
-- RULE
--   Within a (name, country) group, a city joins the cluster of the first
--   known member (by slug) within 50 km of it. A member with either coordinate
--   missing joins the first known anchor (or the first unknown row when none
--   are known), but cannot anchor distant known points. Every known pair in a
--   proposed group must also be within 50 km; ambiguous over-wide groups are
--   withheld. Members now carry
--   region and has_coords so the reviewer sees what the finder saw.
--   Non-city types are unchanged.

create or replace function public._find_duplicate_clusters_body(p_content_type text, p_limit integer default 100)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
  with norm as (
    select sd.entity_id, sd.title, sd.city, sd.country, sd.slug,
           lower(unaccent(btrim(coalesce(sd.title, '')))) as nt,
           coalesce(lower(unaccent(btrim(sd.city))), '')  as nc,
           -- cities only: same name in different countries is two places
           case when p_content_type = 'city'
                then coalesce(lower(unaccent(btrim(sd.country))), '')
                else '' end as nco,
           c.region_name, c.latitude as lat, c.longitude as lng
    from public.search_documents sd
    left join public.cities c
      on p_content_type = 'city' and c.id = sd.entity_id
    where sd.entity_type = p_content_type
      and sd.title is not null
      and length(btrim(sd.title)) >= 3
  ),
  -- only names that occur more than once can form a cluster; anchoring the
  -- whole corpus with a correlated scan took ~50 s, this set is a few dozen rows
  cand as (
    select n.*
    from norm n
    join (select nt, nc, nco from norm group by nt, nc, nco having count(*) > 1) k
      using (nt, nc, nco)
  ),
  anchored as (
    -- cities: the first same-name member (by slug) within 50 km anchors the
    -- cluster; unknown points prefer a known anchor but never anchor known points.
    -- other types: one anchor per group, i.e. the old grouping.
    select n.*,
           case when p_content_type <> 'city' then ''
                else (
                  select a.entity_id::text
                  from cand a
                  where a.nt = n.nt and a.nc = n.nc and a.nco = n.nco
                    and (n.lat is null or n.lng is null
                         or (a.lat is not null and a.lng is not null
                             and public.haversine_m(n.lat, n.lng, a.lat, a.lng) <= 50000))
                  order by (a.lat is null or a.lng is null), a.slug nulls last, a.entity_id
                  limit 1
                ) end as anchor
    from cand n
  ),
  groups as (
    select nt, nc, nco, anchor, count(*) as c,
           jsonb_agg(jsonb_build_object('id', entity_id, 'title', title, 'city', city,
                                        'country', country, 'slug', slug,
                                        'region', region_name,
                                        'has_coords', case when p_content_type = 'city'
                                          then lat is not null and lng is not null else null end)
                     order by slug nulls last) as members
    from anchored
    group by nt, nc, nco, anchor
    having count(*) > 1
      -- Two points can each be within 50 km of an anchor while being 100 km
      -- apart from each other. Do not offer that ambiguous group for merging.
      and (p_content_type <> 'city' or not exists (
        select 1 from anchored a join anchored b
          on a.nt = b.nt and a.nc = b.nc and a.nco = b.nco and a.anchor = b.anchor
        where a.nt = anchored.nt and a.nc = anchored.nc
          and a.nco = anchored.nco and a.anchor = anchored.anchor
          and a.entity_id < b.entity_id
          and a.lat is not null and a.lng is not null
          and b.lat is not null and b.lng is not null
          and public.haversine_m(a.lat, a.lng, b.lat, b.lng) > 50000
      ))
  )
  select coalesce((
    select jsonb_agg(jsonb_build_object('normalized_title', nt, 'city', nullif(nc, ''),
                                        'count', c, 'members', members) order by c desc)
    from (select * from groups order by c desc, nt limit greatest(p_limit, 0)) x
  ), '[]'::jsonb);
$function$;

-- the body stays internal; only the gated wrapper is callable
revoke all on function public._find_duplicate_clusters_body(text, integer) from public, anon, authenticated;

do $verify$
declare
  v jsonb;
  v_bad int;
begin
  v := public._find_duplicate_clusters_body('city', 1000);
  -- no city cluster may hold two members more than 50 km apart
  select count(*) into v_bad
  from jsonb_array_elements(v) g
  cross join lateral jsonb_array_elements(g->'members') m1
  cross join lateral jsonb_array_elements(g->'members') m2
  join public.cities a on a.id = (m1->>'id')::uuid
  join public.cities b on b.id = (m2->>'id')::uuid
  where a.id < b.id
    and a.latitude is not null and b.latitude is not null
    and public.haversine_m(a.latitude, a.longitude, b.latitude, b.longitude) > 50000;
  if v_bad <> 0 then
    raise exception 'postcondition: % city cluster pair(s) more than 50 km apart', v_bad;
  end if;
end
$verify$;
