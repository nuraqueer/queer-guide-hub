-- Write-time guard: a venue, hotel or organization may not be linked to a
-- city in another country than the one its own coordinates are in (2026-10-11).
--
-- WHY. 627 venues were repaired in 99991791714603. Every one had been linked
-- to a same-name city ABROAD ("Valencia" ES for a pin in Valencia VE,
-- "Lincoln" US for a pin in Lincoln UK), and trg_venues_geo_derive then
-- copied that city's country over the correct one -- including over staged
-- data whose own country field was RIGHT (ingestion_staging held "ES" for
-- the Cartagena pins, "NZ" for Nelson, "CW" for Willemstad).
--
-- commit_venue_staging_item has since been fixed (99991791233840 /
-- 99991791356737: city chosen inside the resolved country, 100 km coordinate
-- guard). But that protects ONE writer, and venues.city_id has several:
-- geo-link-content (hourly, resolves by name), the *-city-match functions,
-- backfill scripts, admin edits. A guard in one writer leaves the others
-- open, so it moves to the table -- the same reasoning as
-- trg_staging_human_approval_clears_validation and the phone guard.
--
-- RULE. On INSERT, or an UPDATE that changes city_id / latitude / longitude:
-- refuse (set NULL) a city_id when ALL of these hold --
--   1. the venue and the city both carry coordinates (fail open otherwise);
--   2. they are more than 100 km apart (cheap haversine; a same-metro link
--      never reaches the expensive part -- measured ~9 ms per polygon test,
--      far too much to run on every venue write);
--   3. the coordinates resolve to a country (geo_country_at; offshore,
--      disputed and territory-without-polygon points fail open);
--   4. that country is not the city's country, nor its sovereign/dependency
--      (geo_countries_equivalent);
--   5. the point is at least 25 km outside the city country's own polygon
--      (border towns stay linkable -- the validator excuses <= 2 km, the
--      repair used 25 km).
-- A far city in the SAME country is allowed: rural venues are legitimately
-- attached to a distant town (0 of 289 such links disagreed on country,
-- measured when trg_venues_geo_derive's conflict test was written).
--
-- Because the guard sorts before trg_venues_geo_derive ('c' < 'g'), a
-- refused city never reaches the derive step, so it can no longer drag
-- country_id, state, city text or country text with it. country_id itself is
-- never rewritten here -- the writer's value stands -- but a country that
-- contradicts the coordinates in the same way is stamped, so the nightly
-- containment sweep and a human see it. needs_attention is deliberately NOT
-- raised: it demotes the row to draft, and a contradiction is evidence for a
-- review, not a verdict.
--
-- The refusal is recorded on the row (enrichment_status.city_guard) with the
-- refused city, both countries and the distance, so nothing disappears
-- silently.
--
-- HOTELS AND ORGANIZATIONS get the same function. They are clean today
-- (geo_containment_findings: 0 hotels, 1 organization), so this is
-- prevention, but they are more exposed than venues: besides
-- derive_entity_geo_address they carry tg_city_country_derivation
-- (hotel_city_country_derivation / organization_city_country_derivation),
-- which copies the city's country UNCONDITIONALLY, overwriting even an
-- explicitly written country_id. Their guard triggers are therefore named
-- hotel_aa_... / organization_aa_... so they fire before that trigger as well
-- as before trg_*_geo_derive (same-timing BEFORE triggers fire in name order).
-- The function only reads columns all three tables have: city_id, country_id,
-- latitude, longitude, enrichment_status. The coordinate TYPES differ --
-- venues/organizations are numeric, hotels double precision -- and
-- haversine_m / geo_country_at take numeric only, so every call casts
-- explicitly. Without the casts every hotel write would raise 42883; the
-- hotel probe below is what found it.

create or replace function public.entity_city_country_guard()
returns trigger
language plpgsql
set search_path to 'public', 'extensions'
as $fn$
declare
  v_city_lat  numeric;
  v_city_lng  numeric;
  v_city_cc   text;
  v_km        double precision;
  v_pt_iso    text;
  v_m_outside double precision;
  v_vc        text;
begin
  if new.latitude is null or new.longitude is null then
    return new;
  end if;

  if new.city_id is not null then
    select c.latitude, c.longitude, co.code
      into v_city_lat, v_city_lng, v_city_cc
      from public.cities c
      left join public.countries co on co.id = c.country_id
     where c.id = new.city_id;

    if v_city_lat is not null and v_city_lng is not null and v_city_cc is not null then
      v_km := public.haversine_m(new.latitude::numeric, new.longitude::numeric, v_city_lat, v_city_lng) / 1000.0;
      if v_km > 100 then
        select g.iso_a2 into v_pt_iso from public.geo_country_at(new.latitude::numeric, new.longitude::numeric) g limit 1;
        if v_pt_iso is not null and not public.geo_countries_equivalent(v_city_cc, v_pt_iso) then
          select min(ST_Distance(b.geom::geography,
                                 ST_SetSRID(ST_MakePoint(new.longitude::float8, new.latitude::float8), 4326)::geography))
            into v_m_outside
            from public.geo_boundaries b
           where b.boundary_kind = 'country' and b.iso_a2 = v_city_cc
             and b.geom && ST_Expand(ST_SetSRID(ST_MakePoint(new.longitude::float8, new.latitude::float8), 4326), 0.25);
          -- NULL = no part of the city's country within ~25 km of the point.
          if v_m_outside is null or v_m_outside >= 25000 then
            new.enrichment_status := coalesce(new.enrichment_status, '{}'::jsonb) || jsonb_build_object(
              'city_guard', jsonb_build_object(
                'refused_city_id', new.city_id,
                'city_country', v_city_cc,
                'coord_country', v_pt_iso,
                'km', round(v_km::numeric, 1),
                'at', now()));
            new.city_id := null;
          end if;
        end if;
      end if;
    end if;
  end if;

  -- Stamp (never rewrite) a country_id that contradicts the coordinates.
  if new.country_id is not null
     and (tg_op = 'INSERT' or new.country_id is distinct from old.country_id
          or new.latitude is distinct from old.latitude or new.longitude is distinct from old.longitude) then
    select code into v_vc from public.countries where id = new.country_id;
    if v_pt_iso is null then
      select g.iso_a2 into v_pt_iso from public.geo_country_at(new.latitude::numeric, new.longitude::numeric) g limit 1;
    end if;
    if v_vc is not null and v_pt_iso is not null and not public.geo_countries_equivalent(v_vc, v_pt_iso) then
      select min(ST_Distance(b.geom::geography,
                             ST_SetSRID(ST_MakePoint(new.longitude::float8, new.latitude::float8), 4326)::geography))
        into v_m_outside
        from public.geo_boundaries b
       where b.boundary_kind = 'country' and b.iso_a2 = v_vc
         and b.geom && ST_Expand(ST_SetSRID(ST_MakePoint(new.longitude::float8, new.latitude::float8), 4326), 0.25);
      if v_m_outside is null or v_m_outside >= 25000 then
        new.enrichment_status := coalesce(new.enrichment_status, '{}'::jsonb) || jsonb_build_object(
          'country_conflict', jsonb_build_object('stored', v_vc, 'coord_country', v_pt_iso, 'at', now()));
      end if;
    end if;
  end if;

  return new;
end
$fn$;

revoke all on function public.entity_city_country_guard() from public, anon, authenticated;

drop trigger if exists trg_venues_city_country_guard on public.venues;
create trigger trg_venues_city_country_guard
  before insert or update of city_id, country_id, latitude, longitude on public.venues
  for each row execute function public.entity_city_country_guard();

drop trigger if exists hotel_aa_city_country_guard on public.hotels;
create trigger hotel_aa_city_country_guard
  before insert or update of city_id, country_id, latitude, longitude on public.hotels
  for each row execute function public.entity_city_country_guard();

drop trigger if exists organization_aa_city_country_guard on public.organizations;
create trigger organization_aa_city_country_guard
  before insert or update of city_id, country_id, latitude, longitude on public.organizations
  for each row execute function public.entity_city_country_guard();

do $verify$
declare
  v_es_valencia uuid; v_ve uuid; v_es uuid; v_city uuid; v_country uuid; v_id uuid;
  v_far_same uuid;
begin
  -- The trigger must sort before the derive step, or a refused city would
  -- already have dragged its country along.
  if not ('trg_venues_city_country_guard' < 'trg_venues_geo_derive') then
    raise exception 'guard must sort before trg_venues_geo_derive';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.venues'::regclass
                  and tgname = 'trg_venues_city_country_guard' and tgenabled <> 'D') then
    raise exception 'trg_venues_city_country_guard is not attached';
  end if;
  -- Hotels / organizations: the guard must fire before EVERY trigger that
  -- derives country from city on that table. Checked against the live
  -- catalog, so a derivation trigger added later under a lower name fails here.
  if exists (
    select 1 from pg_trigger t join pg_proc p on p.oid = t.tgfoid
     where t.tgrelid in ('public.venues'::regclass, 'public.hotels'::regclass, 'public.organizations'::regclass)
       and not t.tgisinternal
       and p.proname in ('tg_city_country_derivation', 'derive_entity_geo_address')
       and t.tgname < (select g.tgname from pg_trigger g
                        where g.tgrelid = t.tgrelid and g.tgname like '%city_country_guard'))
  then
    raise exception 'a city->country derivation trigger fires before the guard';
  end if;
  if (select count(*) from pg_trigger where tgname in ('trg_venues_city_country_guard',
        'hotel_aa_city_country_guard', 'organization_aa_city_country_guard') and tgenabled <> 'D') <> 3 then
    raise exception 'guard not attached to all three tables';
  end if;

  -- Behavioural check, rolled back by the exception block: a pin in Valencia,
  -- Venezuela linked to Valencia, Spain must lose the city and keep VE.
  select id into v_ve from public.countries where code = 'VE';
  select id into v_es from public.countries where code = 'ES';
  select c.id into v_es_valencia from public.cities c
   where c.country_id = v_es and lower(c.name) = 'valencia' and c.duplicate_of_id is null
     and c.latitude is not null limit 1;
  if v_ve is null or v_es_valencia is null then
    -- Hard error, not a notice: a skipped probe would read as a passing one.
    raise exception 'guard probe reference rows missing (VE / Valencia ES)';
  end if;
  begin
    insert into public.venues (name, address, latitude, longitude, category, city_id, country_id, city)
    values ('zz guard probe', 'zz guard probe', 10.162, -68.007, 'other', v_es_valencia, v_ve, 'Valencia')
    returning id, city_id, country_id into v_id, v_city, v_country;
    if v_city is not null then
      raise exception 'P1 failed: foreign same-name city was accepted';
    end if;
    if v_country is distinct from v_ve then
      raise exception 'P2 failed: country_id was dragged away from VE';
    end if;
    -- A far city in the SAME country is still accepted (Madrid -> Valencia ES, ~300 km).
    update public.venues set latitude = 40.4168, longitude = -3.7038, country_id = v_es, city_id = v_es_valencia
     where id = v_id returning city_id into v_far_same;
    if v_far_same is distinct from v_es_valencia then
      raise exception 'P3 failed: a same-country far city was refused';
    end if;
    -- Same probe on hotels and organizations, where tg_city_country_derivation
    -- would otherwise overwrite VE with ES unconditionally.
    insert into public.hotels (name, latitude, longitude, city_id, country_id)
    values ('zz guard probe', 10.162, -68.007, v_es_valencia, v_ve)
    returning city_id, country_id into v_city, v_country;
    if v_city is not null or v_country is distinct from v_ve then
      raise exception 'P4 failed: hotel kept the foreign city or lost VE';
    end if;
    insert into public.organizations (name, slug, latitude, longitude, city_id, country_id)
    values ('zz guard probe', 'zz-guard-probe-' || md5(random()::text), 10.162, -68.007, v_es_valencia, v_ve)
    returning city_id, country_id into v_city, v_country;
    if v_city is not null or v_country is distinct from v_ve then
      raise exception 'P5 failed: organization kept the foreign city or lost VE';
    end if;
    raise exception 'guard_probe_ok';
  exception when others then
    if sqlerrm <> 'guard_probe_ok' then raise; end if;
  end;
end
$verify$;
