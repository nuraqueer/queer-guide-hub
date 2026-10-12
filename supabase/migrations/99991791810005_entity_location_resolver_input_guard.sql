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

  IF NOT public.entity_location_country_matches(v_country_id,p_lat,p_lng) THEN
    RETURN QUERY SELECT NULL::uuid,'refused','coordinates',0::numeric,'country_coordinate_conflict',NULL::jsonb; RETURN;
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
