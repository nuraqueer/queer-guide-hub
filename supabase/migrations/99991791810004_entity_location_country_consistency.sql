-- A redirected/merged city must still agree with the requested country and position.
create or replace function public.city_location_evidence_matches(p_city uuid,p_country uuid,p_lat numeric,p_lng numeric)
returns boolean language sql stable set search_path=public,pg_temp as $$
 select exists(select 1 from public.cities c join public.countries co on co.id=c.country_id
 join public.countries wanted on wanted.id=p_country
 where c.id=p_city
 and (c.country_id=p_country or (p_lat is not null and p_lng is not null and public.geo_countries_equivalent(co.code,wanted.code)))
 and (p_lat is null or p_lng is null or c.latitude is null or c.longitude is null
   or public.haversine_m(p_lat,p_lng,c.latitude::numeric,c.longitude::numeric)<=500000))
$$;

CREATE OR REPLACE FUNCTION public.city_region_pick(p_ids uuid[], p_region_code text, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_allow_twin boolean DEFAULT false)
 RETURNS TABLE(city_id uuid, outcome text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_n        int;
  v_one      uuid;
  v_exact_n  int;
  v_exact    uuid;
  v_unc_n    int;
  v_unc      uuid;
  v_far      boolean;
begin
  -- A source coordinate distinguishes distant namesakes even without a region hint.
  if p_lat is not null and p_lng is not null then
    select count(*),(array_agg(s.id))[1] into v_exact_n,v_exact
    from public.cities s where s.id=any(p_ids) and s.latitude is not null and s.longitude is not null
      and public.haversine_m(p_lat,p_lng,s.latitude,s.longitude)<=50000;
    if v_exact_n=1 then return query select v_exact,'match'::text; return; end if;
    if v_exact_n>1 then return query select null::uuid,'ambiguous'::text; return; end if;
    if not exists(select 1 from public.cities s where s.id=any(p_ids)
      and (s.latitude is null or s.longitude is null or public.haversine_m(p_lat,p_lng,s.latitude,s.longitude)<=500000)) then
      return query select null::uuid,'twin'::text; return;
    end if;
  end if;
  select count(*), (array_agg(s.id))[1]
    into v_n, v_one
    from (select distinct unnest(p_ids) as id) x
    join public.cities s on s.id = x.id;

  if coalesce(v_n, 0) = 0 then
    return query select null::uuid, 'none'::text; return;
  end if;

  if p_region_code is null then
    if v_n = 1 then
      return query select v_one, 'match'::text;
    else
      return query select null::uuid, 'ambiguous'::text;
    end if;
    return;
  end if;

  select count(*) filter (where s.region_code = p_region_code),
         (array_agg(s.id) filter (where s.region_code = p_region_code))[1],
         count(*) filter (where s.region_code is null),
         (array_agg(s.id) filter (where s.region_code is null))[1]
    into v_exact_n, v_exact, v_unc_n, v_unc
    from (select distinct unnest(p_ids) as id) x
    join public.cities s on s.id = x.id;

  if v_exact_n = 1 then
    return query select v_exact, 'match'::text; return;
  elsif v_exact_n > 1 then
    return query select null::uuid, 'ambiguous'::text; return;
  end if;

  if v_unc_n = 1 then
    return query select v_unc, 'match'::text; return;
  elsif v_unc_n > 1 then
    return query select null::uuid, 'ambiguous'::text; return;
  end if;

  -- Every candidate sits in a different, known region.
  if p_allow_twin then
    return query select null::uuid, 'twin'::text; return;
  end if;

  if p_lat is not null and p_lng is not null then
    select bool_and(s.latitude is not null and s.longitude is not null
                    and public.haversine_m(p_lat, p_lng, s.latitude, s.longitude) > 50000)
      into v_far
      from (select distinct unnest(p_ids) as id) x
      join public.cities s on s.id = x.id;
    if coalesce(v_far, false) then
      return query select null::uuid, 'twin'::text; return;
    end if;
  end if;

  if v_n = 1 then
    return query select v_one, 'match'::text;
  else
    return query select null::uuid, 'ambiguous'::text;
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.city_resolve_or_create(p_name text, p_country_id uuid DEFAULT NULL::uuid, p_country_code text DEFAULT NULL::text, p_region_hint text DEFAULT NULL::text, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_wikidata_qid text DEFAULT NULL::text, p_source_slug text DEFAULT 'unknown'::text, p_source_entity_id text DEFAULT NULL::text, p_allow_create boolean DEFAULT true, p_actor text DEFAULT 'resolver'::text, p_requester text DEFAULT NULL::text, p_requester_ref uuid DEFAULT NULL::uuid, p_postal_code text DEFAULT NULL::text)
 RETURNS TABLE(city_id uuid, action text, match_type text, confidence numeric, reason text, candidates jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_split       record;
  v_base        text;
  v_region      text;
  v_region_code text;
  v_country_id  uuid := p_country_id;
  v_country_cc  text;
  v_key         text;
  v_nn          text;
  v_lock        bigint;
  v_hit         uuid;
  v_mt          text;
  v_conf        numeric;
  v_cands       jsonb;
  v_cand_count  int := 0;
  v_new_id      uuid;
  v_has_evidence boolean;
  v_postal      text;
  v_postal_hit  uuid;
  v_postal_n    int := 0;
  v_ids         uuid[];
  v_out         text;
  v_twin        boolean := false;
  v_admin       boolean := (p_actor = 'admin');
  v_loc         record;
  v_muni        uuid;
  v_overseas    text;
BEGIN
  p_name := nullif(btrim(p_name), '');
  IF p_name IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, 'refused', 'none', 0::numeric, 'empty_name', NULL::jsonb; RETURN;
  END IF;

  IF v_country_id IS NULL AND nullif(btrim(p_country_code),'') IS NOT NULL THEN
    SELECT c.id INTO v_country_id FROM public.countries c
     WHERE c.code = upper(btrim(p_country_code)) AND c.duplicate_of_id IS NULL LIMIT 1;
  END IF;
  IF v_country_id IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, 'refused', 'none', 0::numeric, 'no_country', NULL::jsonb; RETURN;
  END IF;
  SELECT c.code INTO v_country_cc FROM public.countries c WHERE c.id = v_country_id;

  -- Nominatim reports "fr" for many places in France's overseas territories.
  -- With coordinates inside one, resolve under the territory instead, or every
  -- name arm below misses the territory's row and a France duplicate is minted.
  IF v_country_cc = 'FR' THEN
    v_overseas := public.french_overseas_country_code(p_lat, p_lng);
    IF v_overseas IS NOT NULL THEN
      SELECT c.id INTO v_country_id FROM public.countries c
       WHERE c.code = v_overseas AND c.duplicate_of_id IS NULL LIMIT 1;
      v_country_cc := v_overseas;
    END IF;
  END IF;

  v_base   := p_name;
  v_region := nullif(btrim(p_region_hint), '');
  IF position(',' IN p_name) > 0 THEN
    SELECT * INTO v_split FROM public.geo_split_place_name(p_name);
    IF v_split.did_split THEN
      IF v_split.country_id IS NOT NULL AND v_split.country_id <> v_country_id THEN
        RETURN QUERY SELECT NULL::uuid, 'refused', 'none', 0::numeric, 'country_contradiction',
          jsonb_build_object('stated_country', v_split.country_id, 'given_country', v_country_id);
        RETURN;
      END IF;
      v_base := v_split.base;
      IF v_region IS NULL AND v_split.qualifier_kind <> 'ambiguous' THEN
        v_region := v_split.region_name;
      END IF;
    END IF;
  END IF;

  -- The region as a code. Unresolvable hint text is NOT an error: it simply
  -- carries no identity, and an uncoded hint behaves exactly as before.
  IF v_region IS NOT NULL THEN
    v_region_code := public.resolve_region_code(v_country_cc, v_region);
  END IF;

  v_key := public.city_canonical_key(v_base);
  v_nn  := public.normalize_name(v_base);

  v_lock := hashtextextended(v_country_id::text || '|' || v_nn, 0);
  PERFORM pg_advisory_xact_lock(v_lock);

  -- (a) QID. Deliberately NOT scoped to the country or region.
  IF v_hit IS NULL AND nullif(btrim(p_wikidata_qid),'') IS NOT NULL THEN
    SELECT coalesce(c.duplicate_of_id, c.id) INTO v_hit FROM public.cities c
     WHERE c.wikidata_qid = btrim(p_wikidata_qid) LIMIT 1;
    IF v_hit IS NOT NULL THEN
      v_mt := 'qid'; v_conf := 1.0;
      IF NOT public.city_location_evidence_matches(v_hit,v_country_id,p_lat,p_lng) THEN
        RETURN QUERY SELECT NULL::uuid,'refused','qid',0::numeric,'city_coordinate_or_country_conflict',NULL::jsonb; RETURN;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.cities c WHERE c.id = v_hit AND c.country_id = v_country_id) THEN
        RETURN QUERY SELECT v_hit, 'matched', v_mt, v_conf, 'qid_country_mismatch', NULL::jsonb; RETURN;
      END IF;
    END IF;
  END IF;

  -- (b) The source's own id for this city.
  IF v_hit IS NULL AND nullif(btrim(p_source_entity_id),'') IS NOT NULL THEN
    SELECT coalesce(c.duplicate_of_id, c.id) INTO v_hit
      FROM public.geo_sources gs JOIN public.cities c ON c.id = gs.city_id
     WHERE gs.entity_type = 'city' AND gs.source_slug = p_source_slug
       AND gs.source_entity_id = btrim(p_source_entity_id) LIMIT 1;
    IF v_hit IS NOT NULL THEN v_mt := 'source_key'; v_conf := 0.99; END IF;
  END IF;

  -- (h) Locality of a municipality (Ortsteil / Zinken / Wohnplatz). Never by
  -- name alone: the caller's QID must be the locality's, or the caller's
  -- coordinates must sit within the locality's radius. On a hit the answer is
  -- the MUNICIPALITY; if that has no city row, refuse rather than mint a shell.
  -- Runs BEFORE the name arms: with coordinates in hand, a same-named city
  -- elsewhere in the country (another Alpersbach, Windeck NRW) is not the
  -- place the caller is standing in.
  IF v_hit IS NULL THEN
  SELECT l.* INTO v_loc FROM public.city_localities l
   WHERE l.country_id = v_country_id
     AND (
       (nullif(btrim(p_wikidata_qid),'') IS NOT NULL AND l.locality_qid = btrim(p_wikidata_qid))
       OR (l.locality_key = v_key AND p_lat IS NOT NULL AND p_lng IS NOT NULL
           AND public.haversine_m(p_lat, p_lng, l.anchor_lat, l.anchor_lng) <= l.radius_m)
     )
   ORDER BY (l.locality_qid IS NOT DISTINCT FROM nullif(btrim(p_wikidata_qid),'')) DESC
   LIMIT 1;
  IF FOUND THEN
    IF v_loc.municipality_qid IS NOT NULL THEN
      SELECT coalesce(c.duplicate_of_id, c.id) INTO v_muni FROM public.cities c
       WHERE c.wikidata_qid = v_loc.municipality_qid AND c.country_id = v_country_id LIMIT 1;
    END IF;
    IF v_muni IS NULL THEN
      SELECT coalesce(c.duplicate_of_id, c.id) INTO v_muni FROM public.cities c
       WHERE c.country_id = v_country_id AND c.duplicate_of_id IS NULL
         AND c.canonical_key = public.city_canonical_key(v_loc.municipality_name)
         AND c.latitude IS NOT NULL AND c.longitude IS NOT NULL
         AND public.haversine_m(v_loc.anchor_lat, v_loc.anchor_lng, c.latitude, c.longitude) <= v_loc.radius_m
       LIMIT 1;
    END IF;
    IF v_muni IS NOT NULL THEN
      RETURN QUERY SELECT v_muni, 'matched', 'locality_of_municipality', 0.95::numeric, NULL::text,
        jsonb_build_object('locality', v_loc.locality_name, 'municipality', v_loc.municipality_name);
      RETURN;
    END IF;
    RETURN QUERY SELECT NULL::uuid, 'refused', 'locality_of_municipality', 0::numeric,
      'locality_of_unresolved_municipality',
      jsonb_build_object('locality', v_loc.locality_name, 'municipality', v_loc.municipality_name,
                         'municipality_qid', v_loc.municipality_qid);
    RETURN;
  END IF;
  END IF;

  -- (c)-(f) Name arms. Each collects EVERY same-name survivor in the country
  -- and lets city_region_pick decide; LIMIT 1 here is what used to let the
  -- planner choose between Portland, Maine and Portland, Oregon.

  -- (c) canonical key (TOTAL, merged rows included)
  IF v_hit IS NULL AND NOT v_twin THEN
    SELECT array_agg(DISTINCT coalesce(c.duplicate_of_id, c.id)) INTO v_ids FROM public.cities c
     WHERE c.country_id = v_country_id AND c.canonical_key = v_key;
    IF v_ids IS NOT NULL THEN
      SELECT r.city_id, r.outcome INTO v_hit, v_out
        FROM public.city_region_pick(v_ids, v_region_code, p_lat, p_lng, v_admin) r;
      IF v_out = 'ambiguous' THEN
        RETURN QUERY SELECT NULL::uuid, 'refused', 'canonical_key', 0::numeric, 'ambiguous_region',
          (SELECT jsonb_agg(jsonb_build_object('city_id', s.id, 'name', s.name, 'region_code', s.region_code))
             FROM public.cities s WHERE s.id = ANY (v_ids));
        RETURN;
      END IF;
      v_twin := (v_out = 'twin');
      IF v_hit IS NOT NULL THEN v_mt := 'canonical_key'; v_conf := 0.99; END IF;
    END IF;
  END IF;

  -- (d) lower(name)
  IF v_hit IS NULL AND NOT v_twin THEN
    SELECT array_agg(DISTINCT coalesce(c.duplicate_of_id, c.id)) INTO v_ids FROM public.cities c
     WHERE c.country_id = v_country_id AND lower(c.name) = lower(v_base);
    IF v_ids IS NOT NULL THEN
      SELECT r.city_id, r.outcome INTO v_hit, v_out
        FROM public.city_region_pick(v_ids, v_region_code, p_lat, p_lng, v_admin) r;
      IF v_out = 'ambiguous' THEN
        RETURN QUERY SELECT NULL::uuid, 'refused', 'name_country', 0::numeric, 'ambiguous_region',
          (SELECT jsonb_agg(jsonb_build_object('city_id', s.id, 'name', s.name, 'region_code', s.region_code))
             FROM public.cities s WHERE s.id = ANY (v_ids));
        RETURN;
      END IF;
      v_twin := (v_out = 'twin');
      IF v_hit IS NOT NULL THEN v_mt := 'name_country'; v_conf := 0.98; END IF;
    END IF;
  END IF;

  -- (e) name_normalized, only when it is a real key (non-Latin scripts
  -- normalize to '' and must never match each other).
  IF v_hit IS NULL AND NOT v_twin AND length(v_nn) >= 3 THEN
    SELECT array_agg(DISTINCT coalesce(c.duplicate_of_id, c.id)) INTO v_ids FROM public.cities c
     WHERE c.country_id = v_country_id AND c.name_normalized = v_nn;
    IF v_ids IS NOT NULL THEN
      SELECT r.city_id, r.outcome INTO v_hit, v_out
        FROM public.city_region_pick(v_ids, v_region_code, p_lat, p_lng, v_admin) r;
      IF v_out = 'ambiguous' THEN
        RETURN QUERY SELECT NULL::uuid, 'refused', 'name_normalized', 0::numeric, 'ambiguous_region',
          (SELECT jsonb_agg(jsonb_build_object('city_id', s.id, 'name', s.name, 'region_code', s.region_code))
             FROM public.cities s WHERE s.id = ANY (v_ids));
        RETURN;
      END IF;
      v_twin := (v_out = 'twin');
      IF v_hit IS NOT NULL THEN v_mt := 'name_normalized'; v_conf := 0.98; END IF;
    END IF;
  END IF;

  -- (f) Alias (exonyms: Kapstadt -> Cape Town).
  IF v_hit IS NULL AND NOT v_twin AND length(v_key) >= 3 THEN
    SELECT array_agg(DISTINCT coalesce(c.duplicate_of_id, c.id)) INTO v_ids
      FROM public.city_aliases a JOIN public.cities c ON c.id = a.city_id
     WHERE a.alias_key = v_key AND c.country_id = v_country_id;
    IF v_ids IS NOT NULL THEN
      SELECT r.city_id, r.outcome INTO v_hit, v_out
        FROM public.city_region_pick(v_ids, v_region_code, p_lat, p_lng, v_admin) r;
      IF v_out = 'ambiguous' THEN
        RETURN QUERY SELECT NULL::uuid, 'refused', 'alias', 0::numeric, 'ambiguous_region',
          (SELECT jsonb_agg(jsonb_build_object('city_id', s.id, 'name', s.name, 'region_code', s.region_code))
             FROM public.cities s WHERE s.id = ANY (v_ids));
        RETURN;
      END IF;
      v_twin := (v_out = 'twin');
      IF v_hit IS NOT NULL THEN v_mt := 'alias'; v_conf := 0.95; END IF;
    END IF;
  END IF;

  -- (g) Postal code, opt-in; exactly one city must claim it.
  v_postal := nullif(btrim(p_postal_code), '');
  IF v_postal IS NOT NULL THEN
    SELECT count(DISTINCT coalesce(c.duplicate_of_id, c.id)),
           (array_agg(DISTINCT coalesce(c.duplicate_of_id, c.id)))[1]
      INTO v_postal_n, v_postal_hit
      FROM public.cities c
     WHERE c.country_id = v_country_id
       AND c.postal_codes @> ARRAY[v_postal];

    IF v_hit IS NOT NULL AND v_postal_n = 1 AND v_postal_hit IS DISTINCT FROM v_hit THEN
      RETURN QUERY SELECT NULL::uuid, 'refused', 'postal_conflict', 0::numeric,
        'name_and_postal_disagree',
        jsonb_build_object('by_name', v_hit, 'by_postal', v_postal_hit, 'postal_code', v_postal);
      RETURN;
    END IF;

    IF v_hit IS NULL AND v_postal_n = 1 THEN
      v_hit := v_postal_hit; v_mt := 'postal_code'; v_conf := 0.95;
    END IF;
  END IF;

  IF v_hit IS NOT NULL THEN
    IF NOT public.city_location_evidence_matches(v_hit,v_country_id,p_lat,p_lng) THEN
      RETURN QUERY SELECT NULL::uuid,'refused',v_mt,0::numeric,'city_coordinate_or_country_conflict',NULL::jsonb; RETURN;
    END IF;
    RETURN QUERY SELECT v_hit, 'matched', v_mt, v_conf, NULL::text, NULL::jsonb; RETURN;
  END IF;

  -- No identity hit. Refuse near a different city (< 2 km).
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
    SELECT jsonb_agg(jsonb_build_object(
             'city_id', x.id, 'name', x.name, 'distance_m', round(x.dm)::int,
             'wikidata_qid', x.wikidata_qid)), count(*)
      INTO v_cands, v_cand_count
      FROM (
        SELECT c.id, c.name, c.wikidata_qid,
               public.haversine_m(p_lat, p_lng, c.latitude, c.longitude) AS dm
          FROM public.cities c
         WHERE c.country_id = v_country_id AND c.duplicate_of_id IS NULL
           AND c.latitude IS NOT NULL AND c.longitude IS NOT NULL
           AND abs(c.latitude - p_lat) < 0.03 AND abs(c.longitude - p_lng) < 0.05
           AND public.haversine_m(p_lat, p_lng, c.latitude, c.longitude) < 2000
           AND NOT (c.wikidata_qid IS NOT NULL AND nullif(btrim(p_wikidata_qid),'') IS NOT NULL
                    AND c.wikidata_qid <> btrim(p_wikidata_qid))
         ORDER BY dm LIMIT 5
      ) x;
  END IF;

  IF v_cand_count > 0 THEN
    RETURN QUERY SELECT NULL::uuid, 'refused', 'geo_proximity', 0.85::numeric, 'ambiguous', v_cands;
    RETURN;
  END IF;

  IF NOT p_allow_create THEN
    RETURN QUERY SELECT NULL::uuid, 'refused', 'none', 0::numeric, 'create_not_allowed', NULL::jsonb; RETURN;
  END IF;

  v_has_evidence := (p_lat IS NOT NULL AND p_lng IS NOT NULL)
                 OR nullif(btrim(p_wikidata_qid),'') IS NOT NULL
                 OR nullif(btrim(p_source_entity_id),'') IS NOT NULL
                 OR p_actor = 'admin';

  IF NOT v_has_evidence THEN
    RETURN QUERY SELECT NULL::uuid, 'refused', 'none', 0::numeric, 'insufficient_evidence', NULL::jsonb; RETURN;
  END IF;

  BEGIN
    INSERT INTO public.cities
      (name, country_id, region_name, latitude, longitude, wikidata_qid,
       data_source, last_synced_at, last_refreshed_at, created_at, updated_at,
       field_provenance)
    VALUES
      (v_base, v_country_id, v_region, p_lat, p_lng, nullif(btrim(p_wikidata_qid),''),
       p_source_slug, now(), now(), now(), now(),
       jsonb_build_object('city_resolve', jsonb_build_object(
         'action', CASE WHEN v_twin THEN 'created_region_twin' ELSE 'created' END,
         'source', p_source_slug, 'actor', p_actor, 'at', now())))
    RETURNING id INTO v_new_id;
  EXCEPTION WHEN unique_violation THEN
    -- Someone won the race, or the split trigger rewrote the name into one
    -- that already exists. Re-probe in the SAME region, still under the lock.
    SELECT coalesce(c.duplicate_of_id, c.id) INTO v_hit FROM public.cities c
     WHERE c.country_id = v_country_id AND c.canonical_key = v_key
       AND coalesce(c.region_code, '') = coalesce(v_region_code, '') LIMIT 1;
    IF v_hit IS NULL THEN
      SELECT coalesce(c.duplicate_of_id, c.id) INTO v_hit FROM public.cities c
       WHERE c.country_id = v_country_id AND lower(c.name) = lower(v_base)
         AND coalesce(c.region_code, '') = coalesce(v_region_code, '') LIMIT 1;
    END IF;
    IF v_hit IS NULL THEN
      RETURN QUERY SELECT NULL::uuid, 'refused', 'none', 0::numeric, 'unique_violation_unresolved', NULL::jsonb; RETURN;
    END IF;
    IF NOT public.city_location_evidence_matches(v_hit,v_country_id,p_lat,p_lng) THEN
      RETURN QUERY SELECT NULL::uuid,'refused','canonical_key',0::numeric,'city_coordinate_or_country_conflict',NULL::jsonb; RETURN;
    END IF;
    RETURN QUERY SELECT v_hit, 'raced', 'canonical_key', 0.99::numeric, NULL::text, NULL::jsonb; RETURN;
  END;

  IF nullif(btrim(p_source_entity_id),'') IS NOT NULL THEN
    INSERT INTO public.geo_sources
      (entity_type, city_id, source_slug, source_entity_id, confidence, is_primary, first_seen_at, last_seen_at)
    VALUES ('city', v_new_id, p_source_slug, btrim(p_source_entity_id), 1.0, true, now(), now())
    ON CONFLICT (source_slug, source_entity_id) DO UPDATE SET last_seen_at = now();
  END IF;

  RETURN QUERY SELECT v_new_id, 'created',
    CASE WHEN v_twin THEN 'region_twin' ELSE 'none' END, 1.0::numeric, NULL::text, NULL::jsonb;
END; $function$;
-- The event's source country, address and coordinates corroborate these repairs.
update public.cities set timezone='Europe/Paris' where wikidata_qid='Q160506' and duplicate_of_id is null and timezone is null;
insert into public.city_aliases(city_id,alias,locale)
select c.id,'Valence','fr' from public.cities c join public.countries co on co.id=c.country_id
where c.wikidata_qid='Q8818' and co.code='ES' and c.duplicate_of_id is null
and not exists(select 1 from public.city_aliases a where a.city_id=c.id and a.alias_key=public.city_canonical_key('Valence'));

with plan as (
 select e.id,e.city_id previous_city,c.id correct_city,c.country_id correct_country,
 case co.code when 'FR' then 'Europe/Paris' else 'Europe/Madrid' end correct_timezone
 from public.events e join public.cities old_city on old_city.id=e.city_id
 join public.countries old_co on old_co.id=old_city.country_id
 join public.countries source_co on source_co.id=e.country_id
 join public.cities c on c.wikidata_qid=case when source_co.code='FR' then 'Q160506' else 'Q8818' end and c.duplicate_of_id is null
 join public.countries co on co.id=c.country_id and co.code=source_co.code
 where e.duplicate_of_id is null and e.data_source='agendaq'
 and ((source_co.code='FR' and old_co.code='RE' and e.country='FR' and public.normalize_name(e.city)='saint denis')
   or (source_co.code='ES' and old_co.code='FR' and e.country='ES' and public.normalize_name(e.city)='valence' and e.postal_code like '46%'))
 and e.latitude is not null and e.longitude is not null
 and public.haversine_m(e.latitude::numeric,e.longitude::numeric,c.latitude::numeric,c.longitude::numeric)<25000
), audit as (
 insert into public.entity_location_audit(entity_table,entity_id,source,before_data,patch)
 select 'events',e.id,'agendaq-address-country-coordinates;namesake-repair',to_jsonb(e),
 jsonb_build_object('city_id',p.correct_city,'country_id',p.correct_country,'timezone',p.correct_timezone)
 from plan p join public.events e on e.id=p.id returning entity_id
)
update public.events e set city_id=p.correct_city,country_id=p.correct_country,timezone=p.correct_timezone,
 field_provenance=coalesce(e.field_provenance,'{}')||jsonb_build_object('city_id',jsonb_build_object(
 'source','namesake-country-coordinate-repair','previous_city_id',p.previous_city,'at',now())),updated_at=now()
from plan p where e.id=p.id and e.city_id=p.previous_city;

-- Final checks run after derivation and event venue inheritance. Country/territory
-- equivalence does not excuse a city on another continent. Existing unrelated edits
-- need not revalidate legacy geography; fresh geography writes must be coherent.
create or replace function public.entity_location_country_matches(p_country uuid,p_lat numeric,p_lng numeric)
returns boolean language plpgsql stable security definer set search_path=public,extensions,pg_temp as $$
declare expected text; actual text; outside_m float8;
begin
 if p_country is null or p_lat is null or p_lng is null then return true; end if;
 select code into expected from public.countries where id=p_country;
 select iso_a2 into actual from public.geo_country_at(p_lat,p_lng,0) where match_kind='contains' limit 1;
 if actual is null or expected is null or public.geo_countries_equivalent(actual,expected) then return true; end if;
 select min(ST_Distance(b.geom::geography,ST_SetSRID(ST_MakePoint(p_lng::float8,p_lat::float8),4326)::geography))
 into outside_m from public.geo_boundaries b where b.boundary_kind='country' and b.iso_a2=expected
 and b.geom && ST_Expand(ST_SetSRID(ST_MakePoint(p_lng::float8,p_lat::float8),4326),0.5);
 return outside_m is not null and outside_m<25000;
end $$;
revoke all on function public.entity_location_country_matches(uuid,numeric,numeric) from public,anon,authenticated;
grant execute on function public.entity_location_country_matches(uuid,numeric,numeric) to service_role;
create or replace function public.assert_entity_location_consistency()
returns trigger language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare c public.cities; co_code text; point_code text; outside_m float8;
begin
 if new.city_id is not null and new.country_id is not null then
   select * into c from public.cities where id=new.city_id;
   if c.country_id is not null and c.country_id<>new.country_id and not public.geo_countries_equivalent(
     (select code from countries where id=c.country_id),(select code from countries where id=new.country_id)) then
     raise exception 'City and country conflict: choose a city in the selected country' using errcode='23514';
   end if;
 end if;
 if new.latitude is null or new.longitude is null then return new; end if;
 if new.city_id is not null then
   select * into c from public.cities where id=new.city_id;
   if c.latitude is not null and c.longitude is not null
     and public.haversine_m(new.latitude::numeric,new.longitude::numeric,c.latitude::numeric,c.longitude::numeric)>500000 then
     if tg_op='INSERT' then
       raise exception 'City conflicts with location coordinates: choose the geographically matching city' using errcode='23514';
     elsif new.city_id is distinct from old.city_id then
       raise exception 'City conflicts with location coordinates: choose the geographically matching city' using errcode='23514';
     elsif new.latitude is distinct from old.latitude or new.longitude is distinct from old.longitude then
       new.enrichment_status:=coalesce(new.enrichment_status,'{}')||jsonb_build_object('city_guard',jsonb_build_object(
         'refused_city_id',new.city_id,'reason','coordinate_distance_over_500km','at',now()));
       new.city_id:=null; new.needs_attention:=true;
     end if;
   end if;
 end if;
 if new.country_id is null then return new; end if;
 select code into co_code from public.countries where id=new.country_id;
 select iso_a2 into point_code from public.geo_country_at(new.latitude::numeric,new.longitude::numeric,0) where match_kind='contains' limit 1;
 if point_code is not null and co_code is not null and not public.geo_countries_equivalent(point_code,co_code) then
   select min(ST_Distance(b.geom::geography,ST_SetSRID(ST_MakePoint(new.longitude::float8,new.latitude::float8),4326)::geography))
   into outside_m from public.geo_boundaries b where b.boundary_kind='country' and b.iso_a2=co_code
   and b.geom && ST_Expand(ST_SetSRID(ST_MakePoint(new.longitude::float8,new.latitude::float8),4326),0.5);
   if outside_m is null or outside_m>=25000 then
     raise exception 'Country % conflicts with coordinate country %: correct the location before saving',co_code,point_code using errcode='23514';
   end if;
 end if;
 return new;
end $$;
revoke all on function public.assert_entity_location_consistency() from public,anon,authenticated;
do $$ declare t text; begin
 foreach t in array array['events','venues','hotels','organizations'] loop
 execute format('create trigger zzzz_location_consistency before insert or update of city_id,country_id,latitude,longitude on public.%I for each row execute function public.assert_entity_location_consistency()',t);
 end loop;
end $$;
notify pgrst,'reload schema';

create or replace function public.sync_entity_location_to_organization()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if new.organization_id is null or new.duplicate_of_id is not null then return null; end if;
 update public.organizations o set
   address=coalesce(nullif(btrim(o.address),''),nullif(btrim(new.address),'')),
   country_id=coalesce(o.country_id,new.country_id),
   city_id=coalesce(o.city_id,new.city_id),
   postal_code=coalesce(nullif(btrim(o.postal_code),''),nullif(btrim(new.postal_code),'')),
   latitude=coalesce(o.latitude,new.latitude),longitude=coalesce(o.longitude,new.longitude),
   timezone=coalesce(nullif(btrim(o.timezone),''),nullif(btrim(new.timezone),'')),
   updated_at=now(),
   field_provenance=coalesce(o.field_provenance,'{}') || jsonb_build_object('location_inheritance',
     jsonb_build_object('source_table',tg_table_name,'source_id',new.id,'at',now()))
 where o.id=new.organization_id and o.duplicate_of_id is null
   and public.entity_location_country_matches(new.country_id,new.latitude::numeric,new.longitude::numeric)
   and (new.city_id is null or exists(select 1 from cities c
     left join countries cc on cc.id=c.country_id left join countries co on co.id=new.country_id
     where c.id=new.city_id
       and (new.country_id is null or c.country_id is null or public.geo_countries_equivalent(cc.code,co.code))
       and (new.latitude is null or new.longitude is null or c.latitude is null or c.longitude is null
         or public.haversine_m(new.latitude::numeric,new.longitude::numeric,c.latitude::numeric,c.longitude::numeric)<=500000)))
   and (o.primary_venue_id=new.id or (o.primary_venue_id is null
     and not exists(select 1 from public.venues v where v.organization_id=o.id and v.id<>new.id and v.duplicate_of_id is null)
     and not exists(select 1 from public.hotels h where h.organization_id=o.id and h.id<>new.id and h.duplicate_of_id is null)))
   and (o.city_id is null or new.city_id is null or o.city_id=new.city_id)
   and (o.country_id is null or new.country_id is null or o.country_id=new.country_id)
   and (nullif(btrim(o.address),'') is null or lower(btrim(o.address))=lower(btrim(new.address)))
   and ((nullif(btrim(o.address),'') is null and nullif(btrim(new.address),'') is not null)
     or (o.country_id is null and new.country_id is not null) or (o.city_id is null and new.city_id is not null)
     or (nullif(btrim(o.postal_code),'') is null and nullif(btrim(new.postal_code),'') is not null)
     or (o.latitude is null and new.latitude is not null) or (o.longitude is null and new.longitude is not null)
     or (nullif(btrim(o.timezone),'') is null and nullif(btrim(new.timezone),'') is not null));
 return null;
end $$;
revoke all on function public.sync_entity_location_to_organization() from public,anon,authenticated;

