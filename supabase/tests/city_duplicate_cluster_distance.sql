-- Run after the city cluster migration. Uses the actual deployed function body
-- against temporary fixture tables. All DDL and data are rolled back.
begin;
set local statement_timeout = '30s';
create temporary table qg_cluster_documents (
  entity_id uuid, title text, city text, country text, slug text, entity_type text
);
create temporary table qg_cluster_cities (
  id uuid, region_name text, latitude numeric, longitude numeric
);
insert into qg_cluster_cities values
  ('00000000-0000-0000-0000-000000000001', null, null, null),
  ('00000000-0000-0000-0000-000000000002', 'West', 0, 0),
  ('00000000-0000-0000-0000-000000000003', 'East', 0, 2);
insert into qg_cluster_documents
select id, 'Namesake', null, 'ZZ', 'city-' || id::text, 'city'
from qg_cluster_cities;

do $fixture$
declare src text; result jsonb;
begin
  src := pg_get_functiondef('public._find_duplicate_clusters_body(text,integer)'::regprocedure);
  src := replace(src, 'public._find_duplicate_clusters_body(', 'public._qg_city_cluster_fixture(');
  src := replace(src, 'public.search_documents sd', 'pg_temp.qg_cluster_documents sd');
  src := replace(src, 'public.cities c', 'pg_temp.qg_cluster_cities c');
  execute src;

  -- Unknown coordinates may join a cluster, but cannot bridge known distant cities.
  result := public._qg_city_cluster_fixture('city', 100);
  if jsonb_array_length(result) <> 1 or (result->0->>'count')::int <> 2 then
    raise exception 'unknown point bridged distant city clusters: %', result;
  end if;

  -- One missing coordinate is unknown too; it must remain visible without bridging.
  update qg_cluster_cities set latitude = 0 where longitude is null;
  result := public._qg_city_cluster_fixture('city', 100);
  if jsonb_array_length(result) <> 1 or (result->0->>'count')::int <> 2 then
    raise exception 'partially known point disappeared or bridged clusters: %', result;
  end if;

  -- Both ends are 33 km from the anchor but 67 km from each other.
  update qg_cluster_cities set latitude = 0,
    longitude = case right(id::text, 1) when '1' then 0 when '2' then 0.3 else -0.3 end;
  result := public._qg_city_cluster_fixture('city', 100);
  if result <> '[]'::jsonb then
    raise exception 'shared anchor admitted an over-wide city cluster: %', result;
  end if;

  -- Positive control: a genuinely close cohort is still offered.
  update qg_cluster_cities set longitude = 0.01 * right(id::text, 1)::int;
  result := public._qg_city_cluster_fixture('city', 100);
  if jsonb_array_length(result) <> 1 or (result->0->>'count')::int <> 3 then
    raise exception 'nearby duplicate cities were suppressed: %', result;
  end if;

  -- Other content types retain the original name grouping regardless of distance.
  update qg_cluster_cities set longitude = 2 * right(id::text, 1)::int;
  update qg_cluster_documents set entity_type = 'venue';
  result := public._qg_city_cluster_fixture('venue', 100);
  if jsonb_array_length(result) <> 1 or (result->0->>'count')::int <> 3 then
    raise exception 'non-city grouping changed: %', result;
  end if;
  if exists (
    select 1 from jsonb_array_elements(result->0->'members') member
    where member->'has_coords' is distinct from 'null'::jsonb
  ) then
    raise exception 'non-city rows were labelled as missing city coordinates: %', result;
  end if;
end
$fixture$;
rollback;
