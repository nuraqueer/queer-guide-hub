-- Capture canonical automation failures in the existing admin feedback error queue.
CREATE OR REPLACE FUNCTION public.report_automation_failure(p_run public.admin_automation_runs)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_message text; v_data jsonb; v_status integer;
BEGIN
  IF p_run.finished_at IS NULL OR p_run.status <> 'error' THEN RETURN; END IF;
  v_message := coalesce(nullif(p_run.summary->'requests'->0->>'body',''), p_run.error, 'Automation failed');
  -- Do not copy headers, payloads, or raw request URLs into feedback.
  v_message := left(regexp_replace(v_message, '(Bearer[[:space:]]+|[?&](key|token|secret|api_key)=)[^[:space:]&"'']+', '\1[redacted]', 'gi'), 2000);
  v_status := nullif(p_run.summary->'requests'->0->>'status_code','')::integer;
  v_data := jsonb_build_object('service','automation','function_name',p_run.automation_slug,
    'message',v_message,'status_code',v_status,'endpoint','/admin/automation',
    'reported_at',p_run.finished_at,'metadata',jsonb_build_object('automation_id',p_run.automation_id,
      'run_id',p_run.id,'cron_runid',p_run.cron_runid,'auto_paused',coalesce((p_run.summary->>'auto_paused')::boolean,false)));
  INSERT INTO public.community_submissions(content_type,data,fingerprint,occurrence_count,last_seen_at,feedback_status,labels)
  VALUES('api_error',v_data,'automation:'||p_run.automation_slug,1,p_run.finished_at,'new',ARRAY['automation'])
  ON CONFLICT(fingerprint) WHERE content_type='api_error' AND fingerprint IS NOT NULL
  DO UPDATE SET occurrence_count=public.community_submissions.occurrence_count+1,
    last_seen_at=excluded.last_seen_at, data=excluded.data,
    feedback_status=CASE WHEN public.community_submissions.feedback_status='done' THEN 'new' ELSE public.community_submissions.feedback_status END,
    resolution=CASE WHEN public.community_submissions.feedback_status='done' THEN NULL ELSE public.community_submissions.resolution END,
    resolved_at=CASE WHEN public.community_submissions.feedback_status='done' THEN NULL ELSE public.community_submissions.resolved_at END
  WHERE coalesce((public.community_submissions.data->'metadata'->>'run_id')::bigint,0)<p_run.id;
END $fn$;
REVOKE ALL ON FUNCTION public.report_automation_failure(public.admin_automation_runs) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.automation_failure_feedback_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  IF NEW.finished_at IS NOT NULL AND NEW.status='error' AND
     (TG_OP='INSERT' OR OLD.finished_at IS NULL OR OLD.status IS DISTINCT FROM NEW.status) THEN
    PERFORM public.report_automation_failure(NEW);
  END IF;
  RETURN NEW;
END $fn$;
REVOKE ALL ON FUNCTION public.automation_failure_feedback_trigger() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER automation_failure_feedback AFTER INSERT OR UPDATE ON public.admin_automation_runs
FOR EACH ROW EXECUTE FUNCTION public.automation_failure_feedback_trigger();

-- One latest failure per automation seeds the backlog without flooding the queue.
DO $fn$ DECLARE r public.admin_automation_runs; BEGIN
  FOR r IN SELECT DISTINCT ON (automation_slug) * FROM public.admin_automation_runs
    WHERE status='error' AND finished_at IS NOT NULL AND started_at>now()-interval '30 days'
    ORDER BY automation_slug,id DESC
  LOOP PERFORM public.report_automation_failure(r); END LOOP;
END $fn$;

CREATE OR REPLACE FUNCTION public.run_event_programme_link(p_batch integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_linked integer := 0;
  v_ambiguous integer := 0;
begin
  with live as (
    select e.id, e.start_date, coalesce(e.end_date, e.start_date) as end_date,
           e.city_id, e.parent_event_id,
           public.dedup_core_tokens(e.title) as toks,
           coalesce(public.dedup_core_tokens(ci.name), '{}'::text[])
             || coalesce(public.dedup_core_tokens(e.city), '{}'::text[]) as city_toks
    from public.events e
    left join public.cities ci on ci.id = e.city_id
    where e.duplicate_of_id is null
      and e.status = 'active'
      and e.city_id is not null
      and e.title is not null
  ),
  cand as (
    select c.id as child_id, p.id as parent_id
    from live p
    join live c
      on c.id <> p.id
     and c.city_id = p.city_id
     -- The umbrella spans more than a day and strictly contains the child. The 6h
     -- slack absorbs a child whose end is stamped just past midnight.
     and p.end_date - p.start_date >= interval '20 hours'
     and c.end_date - c.start_date < p.end_date - p.start_date
     and c.start_date >= p.start_date
     and c.end_date <= p.end_date + interval '6 hours'
    where c.parent_event_id is null
      -- The parent must itself be top-level, and the child must not already be a
      -- parent: events_programme_depth_guard() rejects a two-level chain, so
      -- building one here would raise rather than link.
      and p.parent_event_id is null
      and not exists (select 1 from public.events x where x.parent_event_id = c.id)
      and cardinality(
            array(select unnest(p.toks) intersect select unnest(c.toks)
                  except select unnest(p.city_toks))
          ) >= 2
  ),
  grouped as (
    -- `min(uuid)` does not exist in Postgres — hence array_agg.
    select child_id,
           count(distinct parent_id) as n_parents,
           (array_agg(parent_id order by parent_id))[1] as parent_id
    from cand
    group by child_id
  ),
  picked as (
    -- Two candidate umbrellas means we cannot tell which one owns the child, and a
    -- wrong parent is not self-correcting. Block rather than guess.
    select g.child_id, g.parent_id from grouped g
    where g.n_parents = 1
      and not exists (select 1 from cand p where p.parent_id=g.child_id)
    order by g.child_id limit greatest(0,least(p_batch,200))
  ),
  upd as (
    update public.events e
       set parent_event_id = pk.parent_id
      from picked pk
     where e.id = pk.child_id
    returning 1
  )
  select (select count(*) from upd)::integer,
         -- Reported, not silently dropped: a blocked child is work for a human, and
         -- a run that links nothing because everything is ambiguous must not read
         -- the same as a run with nothing to do.
         (select count(*) from grouped where n_parents > 1)::integer
    into v_linked, v_ambiguous;

  return jsonb_build_object('linked', v_linked, 'ambiguous', v_ambiguous);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.link_event_venues(p_limit integer DEFAULT 500, p_active_only boolean DEFAULT true, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_candidates int := 0;
  v_linked     int := 0;
  v_queued     int := 0;
BEGIN
  PERFORM public.assert_admin_or_internal();

  -- Report pass (also the dry-run result).
  WITH cand AS (
    SELECT * FROM public.find_event_venue_candidates(p_limit, p_active_only)
  ),
  exact_ok AS (
    SELECT * FROM cand
    WHERE name_exact AND (distance_m IS NULL OR distance_m < 100000)
      AND NOT EXISTS (
        SELECT 1 FROM public.events src JOIN public.events other
          ON lower(btrim(other.title))=lower(btrim(src.title))
         AND other.start_date=src.start_date AND other.venue_id=cand.venue_id
         AND other.status <> 'archived' AND other.id<>src.id
        WHERE src.id=cand.event_id)
      AND NOT EXISTS (
        SELECT 1 FROM cand sibling JOIN public.events se ON se.id=sibling.event_id
          JOIN public.events ce ON ce.id=cand.event_id
        WHERE sibling.event_id<>cand.event_id AND sibling.venue_id=cand.venue_id
          AND lower(btrim(se.title))=lower(btrim(ce.title)) AND se.start_date=ce.start_date)
  ),
  auto AS (
    SELECT event_id FROM exact_ok GROUP BY event_id HAVING count(*) = 1
  )
  SELECT (SELECT count(DISTINCT c.event_id) FROM cand c),
         (SELECT count(*) FROM auto),
         (SELECT count(DISTINCT c.event_id) FROM cand c
           WHERE c.event_id NOT IN (SELECT a.event_id FROM auto a))
    INTO v_candidates, v_linked, v_queued;

  IF NOT p_dry_run THEN
    WITH cand AS (
      SELECT * FROM public.find_event_venue_candidates(p_limit, p_active_only)
    ),
    exact_ok AS (
      SELECT * FROM cand
      WHERE name_exact AND (distance_m IS NULL OR distance_m < 100000)
      AND NOT EXISTS (
        SELECT 1 FROM public.events src JOIN public.events other
          ON lower(btrim(other.title))=lower(btrim(src.title))
         AND other.start_date=src.start_date AND other.venue_id=cand.venue_id
         AND other.status <> 'archived' AND other.id<>src.id
        WHERE src.id=cand.event_id)
      AND NOT EXISTS (
        SELECT 1 FROM cand sibling JOIN public.events se ON se.id=sibling.event_id
          JOIN public.events ce ON ce.id=cand.event_id
        WHERE sibling.event_id<>cand.event_id AND sibling.venue_id=cand.venue_id
          AND lower(btrim(se.title))=lower(btrim(ce.title)) AND se.start_date=ce.start_date)
    ),
    auto AS (
      SELECT event_id,
             (array_agg(venue_id))[1]   AS venue_id,
             (array_agg(distance_m))[1] AS distance_m
      FROM exact_ok GROUP BY event_id HAVING count(*) = 1
    ),
    upd AS (
      UPDATE public.events e
         SET venue_id = a.venue_id,
             field_provenance = jsonb_set(
               coalesce(e.field_provenance, '{}'::jsonb), ARRAY['venue_id'],
               jsonb_build_object(
                 'value', a.venue_id, 'confidence', 0.95,
                 'source', 'name_city_match', 'linked_at', now()), true)
        FROM auto a
       WHERE e.id = a.event_id AND e.venue_id IS NULL
      RETURNING e.id, a.venue_id, a.distance_m
    ),
    sig AS (
      INSERT INTO public.event_quality_signals (event_id, signal_type, value, source, details)
      SELECT u.id, 'enrichment', 0.95, 'link_event_venues',
             jsonb_build_object('venue_id', u.venue_id, 'match', 'name_city_match',
                                'distance_m', u.distance_m)
      FROM upd u
      RETURNING 1
    ),
    review AS (
      SELECT DISTINCT c.event_id, c.event_venue_name
      FROM cand c
      WHERE c.event_id NOT IN (SELECT a.event_id FROM auto a)
    ),
    rq AS (
      INSERT INTO public.review_queue (entity_type, entity_id, review_type, status, details)
      SELECT 'event', r.event_id, 'venue_link_candidate', 'pending',
             jsonb_build_object(
               'event_venue_name', r.event_venue_name,
               'candidates', (SELECT jsonb_agg(jsonb_build_object(
                                'venue_id', c2.venue_id, 'venue_name', c2.venue_name,
                                'name_exact', c2.name_exact, 'distance_m', c2.distance_m))
                              FROM cand c2 WHERE c2.event_id = r.event_id),
               'source', 'link_event_venues')
      FROM review r
      WHERE NOT EXISTS (
        SELECT 1 FROM public.review_queue q
        WHERE q.entity_type = 'event' AND q.entity_id = r.event_id
          AND q.review_type = 'venue_link_candidate' AND q.status = 'pending')
      RETURNING 1
    )
    SELECT (SELECT count(*) FROM upd), (SELECT count(*) FROM rq)
      INTO v_linked, v_queued;
  END IF;

  RETURN jsonb_build_object(
    'dry_run', p_dry_run, 'candidates', v_candidates,
    'linked', v_linked, 'queued_for_review', v_queued);
END; $function$
;

CREATE OR REPLACE FUNCTION public.venues_misplaced(p_limit integer DEFAULT NULL::integer)
 RETURNS TABLE(venue_id uuid, name text, address text, is_geocodable boolean, city_id uuid, city_name text, country_id uuid, km_to_linked numeric, nearest_other_city text, km_to_nearest numeric, cur_lat numeric, cur_lng numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  WITH base AS MATERIALIZED (
    SELECT v.id, v.name, v.address,
           (v.address IS NOT NULL
            AND length(btrim(v.address)) >= 6
            AND lower(btrim(v.address)) <> lower(btrim(v.name))) AS is_geocodable,
           v.city_id, c.name AS city_name,
           coalesce(v.country_id, c.country_id) AS eff_country_id,
           v.latitude::float AS vlat, v.longitude::float AS vlng,
           ST_DistanceSphere(ST_MakePoint(v.longitude::float, v.latitude::float),
                             ST_MakePoint(c.longitude::float, c.latitude::float))/1000.0 AS km_linked
    FROM public.venues v
    JOIN public.cities c ON c.id = v.city_id
    WHERE v.duplicate_of_id IS NULL
      AND v.latitude IS NOT NULL AND v.longitude IS NOT NULL
      AND c.latitude IS NOT NULL AND c.longitude IS NOT NULL
      AND extensions.ST_DistanceSphere(extensions.ST_MakePoint(v.longitude::float,v.latitude::float),
          extensions.ST_MakePoint(c.longitude::float,c.latitude::float)) > 8000
  ),
  near AS (
    SELECT b.*, n.name AS other_name, n.km AS other_km
    FROM base b
    LEFT JOIN LATERAL (
      SELECT c2.name,
             ST_DistanceSphere(ST_MakePoint(b.vlng, b.vlat),
                               ST_MakePoint(c2.longitude::float, c2.latitude::float))/1000.0 AS km
      FROM public.cities c2
      WHERE c2.id <> b.city_id
        AND c2.latitude IS NOT NULL AND c2.longitude IS NOT NULL
        AND (b.eff_country_id IS NULL OR c2.country_id = b.eff_country_id)
      ORDER BY ST_MakePoint(c2.longitude::float, c2.latitude::float) <-> ST_MakePoint(b.vlng, b.vlat)
      LIMIT 1
    ) n ON true
    WHERE b.km_linked > 8.0
      AND ( b.km_linked > 50.0
            OR (n.km IS NOT NULL AND n.km < b.km_linked)
          )
  )
  SELECT id, name, address, is_geocodable, city_id, city_name, eff_country_id,
         round(km_linked::numeric,2), other_name, round(other_km::numeric,2),
         vlat::numeric, vlng::numeric
  FROM near
  ORDER BY km_linked DESC
  LIMIT p_limit;
$function$
;

CREATE INDEX IF NOT EXISTS marketplace_upscale_pending_idx ON public.marketplace_listings(id)
WHERE status='active' AND images IS NOT NULL AND cardinality(images)>0
  AND NOT coalesce(attributes->'image_upscale' ? 'resolved_at',false)
  AND coalesce((attributes->'image_upscale'->>'attempts')::int,0)<3;
CREATE INDEX IF NOT EXISTS marketplace_link_stale_idx ON public.marketplace_listings(link_checked_at NULLS FIRST,id,last_seen_at)
WHERE status='active';
CREATE INDEX IF NOT EXISTS events_image_quality_candidates_idx ON public.events(updated_at DESC,id)
WHERE duplicate_of_id IS NULL AND cardinality(coalesce(images,'{}'::text[]))>0;

CREATE OR REPLACE FUNCTION public.refresh_business_brand_quality()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_findings integer:=0; v_batch integer:=0; v_orgs integer:=0; v_brands integer:=0;
  v_snapshot bigint; v_stats jsonb; v_by_role jsonb; v_by_brand_state jsonb;
begin
  perform public.reconcile_organization_link_roles();
  perform public.link_brand_organization_domain_matches(500);

  with org as (
    select o.*,
      exists(select 1 from venues v where v.organization_id=o.id and v.duplicate_of_id is null)
      or exists(select 1 from hotels h where h.organization_id=o.id and h.duplicate_of_id is null)
      or exists(select 1 from marketplace_merchants m where m.organization_id=o.id)
      or exists(select 1 from marketplace_brands b where b.organization_id=o.id)
      or exists(select 1 from affiliate_partners a where a.organization_id=o.id)
      or exists(select 1 from news_sources n where n.organization_id=o.id) has_link
    from organizations o where o.duplicate_of_id is null
  ), rows as (
    select 'organization'::text entity_type,o.id entity_id,v.dimension,
      v.state,v.reason_code,v.evidence
    from org o cross join lateral (values
      ('identity',case when nullif(btrim(o.name),'') is not null and nullif(btrim(o.slug),'') is not null then 'pass' else 'fail' end,
        case when nullif(btrim(o.name),'') is not null and nullif(btrim(o.slug),'') is not null then 'identity_complete' else 'identity_missing' end,jsonb_build_object('name',o.name,'slug',o.slug)),
      ('editorial',case when length(coalesce(btrim(o.description),''))>=80 then 'pass' else 'fail' end,
        case when length(coalesce(btrim(o.description),''))>=80 then 'description_usable' else 'description_missing_or_thin' end,jsonb_build_object('length',length(coalesce(btrim(o.description),'')))),
      ('contact',case when coalesce(o.website,o.email,o.phone) is not null or o.social<>'{}'::jsonb then 'pass' else 'fail' end,
        case when coalesce(o.website,o.email,o.phone) is not null or o.social<>'{}'::jsonb then 'contact_available' else 'contact_missing' end,jsonb_build_object('website',o.website is not null,'email',o.email is not null,'phone',o.phone is not null,'social',o.social<>'{}'::jsonb)),
      ('location',case when not(o.roles && array['venue','hotel','support','community','advocacy']::text[]) then 'not_applicable'
        when (o.city_id is not null and o.country_id is not null) or (o.latitude is not null and o.longitude is not null) then 'pass' else 'fail' end,
        case when not(o.roles && array['venue','hotel','support','community','advocacy']::text[]) then 'role_has_no_location_requirement'
          when (o.city_id is not null and o.country_id is not null) or (o.latitude is not null and o.longitude is not null) then 'location_complete' else 'location_missing' end,
        jsonb_build_object('city_id',o.city_id,'country_id',o.country_id,'coordinates',o.latitude is not null and o.longitude is not null)),
      ('media',case when o.logo_url is not null or o.cover_image_url is not null or cardinality(o.images)>0 then 'pass' else 'fail' end,
        case when o.logo_url is not null or o.cover_image_url is not null or cardinality(o.images)>0 then 'media_available' else 'media_missing' end,jsonb_build_object('logo',o.logo_url is not null,'cover',o.cover_image_url is not null,'images',cardinality(o.images))),
      ('categorization',case when cardinality(o.roles)>0 then 'pass' else 'fail' end,
        case when cardinality(o.roles)>0 then 'roles_present' else 'roles_missing' end,jsonb_build_object('roles',o.roles,'tags',o.tags,'target_groups',o.target_groups)),
      ('linkage',case when o.has_link or o.linkage_disposition in('standalone','not_applicable') then 'pass'
        when o.linkage_disposition='needs_review' then 'fail' else 'pending' end,
        case when o.has_link then 'linked_entity_present' when o.linkage_disposition='standalone' then 'verified_standalone'
          when o.linkage_disposition='not_applicable' then 'link_not_applicable' when o.linkage_disposition='needs_review' then 'expected_link_missing' else 'linkage_unresolved' end,
        jsonb_build_object('disposition',o.linkage_disposition)),
      ('provenance',case when o.field_provenance<>'{}'::jsonb then 'pass' else 'fail' end,
        case when o.field_provenance<>'{}'::jsonb then 'field_provenance_present' else 'field_provenance_missing' end,
        jsonb_build_object('fields',(select count(*) from jsonb_object_keys(o.field_provenance)))),
      ('freshness',case when o.last_verified_at is null then 'pending' when o.last_verified_at>=now()-interval '365 days' then 'pass' else 'fail' end,
        case when o.last_verified_at is null then 'never_verified' when o.last_verified_at>=now()-interval '365 days' then 'verified_within_365d' else 'verification_stale' end,jsonb_build_object('last_verified_at',o.last_verified_at))
    ) v(dimension,state,reason_code,evidence)
  )
  insert into entity_quality_findings(entity_type,entity_id,dimension,state,reason_code,evidence)
  select entity_type,entity_id,dimension,state,reason_code,evidence from rows
  on conflict(entity_type,entity_id,dimension) do update set
    state=excluded.state,reason_code=excluded.reason_code,evidence=excluded.evidence,
    source=excluded.source,checked_at=now(),waived_at=case when entity_quality_findings.reason_code is distinct from excluded.reason_code then null else entity_quality_findings.waived_at end,
    waived_by=case when entity_quality_findings.reason_code is distinct from excluded.reason_code then null else entity_quality_findings.waived_by end,
    waiver_note=case when entity_quality_findings.reason_code is distinct from excluded.reason_code then null else entity_quality_findings.waiver_note end;
  get diagnostics v_findings=row_count;

  with actual as (
    select b.id,b.brand_key,count(l.id)::int n
    from marketplace_brands b left join marketplace_listings l
      on l.brand_key=b.brand_key and l.status='active' and l.duplicate_of_id is null
    group by b.id,b.brand_key
  ), rows as (
    select 'marketplace_brand'::text entity_type,b.id entity_id,v.dimension,v.state,v.reason_code,v.evidence
    from marketplace_brands b join actual a on a.id=b.id
    cross join lateral (values
      ('identity',case when b.slug is not null and nullif(btrim(b.display_name),'') is not null and b.product_count>0 then 'pass' else 'fail' end,
        case when b.slug is null then 'slug_missing' when b.product_count=0 then 'no_active_products' else 'identity_complete' end,jsonb_build_object('slug',b.slug,'display_name',b.display_name,'products',b.product_count)),
      ('editorial',case when length(coalesce(btrim(b.story),''))>=80 then 'pass'
        when b.profile_resolution->>'story'='source_unavailable' then 'source_unavailable' else 'fail' end,
        case when length(coalesce(btrim(b.story),''))>=80 then 'story_usable' when b.profile_resolution->>'story'='source_unavailable' then 'story_source_unavailable' else 'story_missing_or_thin' end,jsonb_build_object('length',length(coalesce(btrim(b.story),'')))),
      ('contact',case when b.website is not null then 'pass' when b.profile_resolution->>'website'='source_unavailable' then 'source_unavailable' else 'fail' end,
        case when b.website is not null then 'website_available' when b.profile_resolution->>'website'='source_unavailable' then 'website_source_unavailable' else 'website_missing' end,jsonb_build_object('website',b.website)),
      ('media',case when b.logo_url is not null then 'pass' when b.logo_fetched_at is not null or b.profile_resolution->>'logo'='source_unavailable' then 'source_unavailable' else 'pending' end,
        case when b.logo_url is not null then 'logo_available' when b.logo_fetched_at is not null then 'logo_lookup_exhausted' else 'logo_lookup_pending' end,jsonb_build_object('logo_url',b.logo_url,'logo_fetched_at',b.logo_fetched_at)),
      ('linkage',case when b.organization_id is not null then 'pass' when b.profile_resolution->>'organization'='source_unavailable' then 'source_unavailable' else 'pending' end,
        case when b.organization_id is not null then 'organization_linked' when b.profile_resolution->>'organization'='source_unavailable' then 'organization_source_unavailable' else 'organization_link_pending' end,jsonb_build_object('organization_id',b.organization_id)),
      ('ownership',case when b.ownership_review_status in('verified','not_applicable','rejected') then 'pass'
        when b.ownership_review_status='needs_review' then 'fail' else 'pending' end,
        'ownership_'||b.ownership_review_status,jsonb_build_object('status',b.ownership_review_status,'tags',b.ownership_tags,'evidence',b.evidence,'reviewed_at',b.reviewed_at)),
      ('product_linkage',case when b.product_count=a.n then 'pass' else 'fail' end,
        case when b.product_count=a.n then 'product_count_matches' else 'product_count_drift' end,jsonb_build_object('stored',b.product_count,'actual',a.n)),
      ('provenance',case when b.detection_source is not null and (cardinality(b.ownership_tags)=0 or nullif(btrim(b.evidence),'') is not null) then 'pass' else 'fail' end,
        case when cardinality(b.ownership_tags)>0 and nullif(btrim(b.evidence),'') is null then 'ownership_evidence_missing' else 'brand_provenance_present' end,jsonb_build_object('detection_source',b.detection_source,'evidence',b.evidence))
    ) v(dimension,state,reason_code,evidence)
    where b.product_count>0 or b.publication_status='published'
  )
  insert into entity_quality_findings(entity_type,entity_id,dimension,state,reason_code,evidence)
  select entity_type,entity_id,dimension,state,reason_code,evidence from rows
  on conflict(entity_type,entity_id,dimension) do update set
    state=excluded.state,reason_code=excluded.reason_code,evidence=excluded.evidence,
    source=excluded.source,checked_at=now(),waived_at=case when entity_quality_findings.reason_code is distinct from excluded.reason_code then null else entity_quality_findings.waived_at end,
    waived_by=case when entity_quality_findings.reason_code is distinct from excluded.reason_code then null else entity_quality_findings.waived_by end,
    waiver_note=case when entity_quality_findings.reason_code is distinct from excluded.reason_code then null else entity_quality_findings.waiver_note end;
  get diagnostics v_batch=row_count;
  v_findings:=v_findings+v_batch;

  with d as (
    select entity_id,jsonb_object_agg(dimension,jsonb_build_object('state',state,'reason_code',reason_code,'waived',waived_at is not null)) dimensions,
      round(100.0*count(*)filter(where state='pass' or waived_at is not null)/nullif(count(*)filter(where state<>'not_applicable'),0))::smallint score
    from entity_quality_findings where entity_type='organization' group by entity_id
  ) update organizations o set quality_dimensions=d.dimensions,quality_checked_at=now(),completeness_score=coalesce(d.score,0),needs_attention=coalesce(d.score,0)<60
    from d where d.entity_id=o.id
    AND (o.quality_dimensions IS DISTINCT FROM d.dimensions
      OR o.completeness_score IS DISTINCT FROM coalesce(d.score,0)
      OR o.needs_attention IS DISTINCT FROM (coalesce(d.score,0)<60));
  get diagnostics v_orgs=row_count;

  with d as (
    select entity_id,jsonb_object_agg(dimension,jsonb_build_object('state',state,'reason_code',reason_code,'waived',waived_at is not null)) dimensions
    from entity_quality_findings where entity_type='marketplace_brand' group by entity_id
  ) update marketplace_brands b set quality_dimensions=d.dimensions,quality_checked_at=now()
    from d where d.entity_id=b.id;
  get diagnostics v_brands=row_count;

  select jsonb_build_object(
      'organizations_total',(select count(*) from organizations where duplicate_of_id is null),
      'organizations_open',(select count(*) from entity_quality_findings where entity_type='organization' and state in('fail','pending') and waived_at is null),
      'brands_total',(select count(*) from marketplace_brands where product_count>0),
      'brands_open',(select count(*) from entity_quality_findings where entity_type='marketplace_brand' and state in('fail','pending') and waived_at is null),
      'ownership_needs_review',(select count(*) from marketplace_brands where ownership_review_status='needs_review'),
      'brand_product_count_drift',(select count(*) from entity_quality_findings where entity_type='marketplace_brand' and reason_code='product_count_drift' and state='fail'),
      'roles_link_mismatch',(select count(*) from organizations o where o.duplicate_of_id is null and (
        (exists(select 1 from venues v where v.organization_id=o.id and v.duplicate_of_id is null) and not('venue'=any(o.roles)))
        or (exists(select 1 from hotels h where h.organization_id=o.id and h.duplicate_of_id is null) and not('hotel'=any(o.roles)))
        or (exists(select 1 from marketplace_merchants m where m.organization_id=o.id) and not('seller'=any(o.roles)))
        or (exists(select 1 from marketplace_brands b where b.organization_id=o.id) and not('brand'=any(o.roles)))
        or (exists(select 1 from affiliate_partners a where a.organization_id=o.id) and not('affiliate_partner'=any(o.roles)))
        or (exists(select 1 from news_sources n where n.organization_id=o.id) and not('publisher'=any(o.roles))))),
      'findings_by_state',(select jsonb_object_agg(state,n) from(select state,count(*) n from entity_quality_findings group by state)x),
      'findings_by_reason',(select jsonb_object_agg(reason_code,n) from(select reason_code,count(*) n from entity_quality_findings group by reason_code)x),
      'brands_by_source',(select coalesce(jsonb_object_agg(source_name,n),'{}'::jsonb) from(
        select coalesce(nullif(detection_source,''),'unknown') source_name,count(*) n
        from marketplace_brands where product_count>0 group by 1)x)
    ),
    (select coalesce(jsonb_object_agg(role,n),'{}'::jsonb) from(select role,count(*) n from organizations o cross join lateral unnest(o.roles) role where o.duplicate_of_id is null group by role)x),
    (select coalesce(jsonb_object_agg(publication_status||'/'||ownership_review_status,n),'{}'::jsonb) from(select publication_status,ownership_review_status,count(*) n from marketplace_brands group by 1,2)x)
  into v_stats,v_by_role,v_by_brand_state;

  update marketplace_quality_snapshots set business_brand_stats=v_stats,
    business_brand_by_role=v_by_role,business_brand_by_brand_state=v_by_brand_state
  where id=(select id from marketplace_quality_snapshots order by taken_at desc limit 1)
  returning id into v_snapshot;
  if v_snapshot is null then
    perform public.run_marketplace_quality_snapshot();
    update marketplace_quality_snapshots set business_brand_stats=v_stats,
      business_brand_by_role=v_by_role,business_brand_by_brand_state=v_by_brand_state
    where id=(select id from marketplace_quality_snapshots order by taken_at desc limit 1)
    returning id into v_snapshot;
  end if;

  with keys(key) as (values('organizations_open'),('brands_open')),
  series as (
    select k.key,array_agg((q.business_brand_stats->>k.key)::numeric order by q.taken_at desc) values_desc
    from keys k cross join lateral (
      select business_brand_stats,taken_at from marketplace_quality_snapshots
      where business_brand_stats is not null order by taken_at desc limit 3
    ) q group by k.key
  ), growing as (
    select key,values_desc from series where cardinality(values_desc)=3
      and values_desc[1]>values_desc[2] and values_desc[2]>values_desc[3]
  )
  insert into marketplace_quality_alerts(alert_type,dedupe_key,severity,message,details)
  select 'business_brand_backlog_growth','business-brand:'||key,'warning',
    key||' grew for two consecutive snapshots',jsonb_build_object('values',values_desc)
  from growing on conflict(dedupe_key) where resolved_at is null do update
    set last_seen_at=now(),details=excluded.details,message=excluded.message;

  with keys(key) as (values('organizations_open'),('brands_open')),
  series as (
    select k.key,array_agg((q.business_brand_stats->>k.key)::numeric order by q.taken_at desc) values_desc
    from keys k cross join lateral (
      select business_brand_stats,taken_at from marketplace_quality_snapshots
      where business_brand_stats is not null order by taken_at desc limit 3
    ) q group by k.key
  )
  update marketplace_quality_alerts a set resolved_at=now()
  where a.alert_type='business_brand_backlog_growth' and a.resolved_at is null
    and not exists(select 1 from series s where a.dedupe_key='business-brand:'||s.key
      and cardinality(s.values_desc)=3 and s.values_desc[1]>s.values_desc[2]
      and s.values_desc[2]>s.values_desc[3]);

  return jsonb_build_object('findings_upserted',v_findings,'organizations_scored',v_orgs,'brands_scored',v_brands,'snapshot_id',v_snapshot);
end;
$function$
;

UPDATE public.admin_automations SET enabled=false,lifecycle_state='retired',consecutive_failures=0,
 description='Retired: enrich-wolfram-countries was removed; country enrichment is handled by country editorial and factual workflows.'
WHERE slug='wf_enrich_wolfram_countries';


CREATE OR REPLACE FUNCTION public.marketplace_enhance_claim(p_limit integer DEFAULT 30)
 RETURNS SETOF uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF (SELECT count(*) FROM public.marketplace_enhance_queue) = 0 THEN
    PERFORM public.marketplace_enhance_refill(200);
  END IF;
  RETURN QUERY
  WITH pick AS (
    SELECT listing_id FROM public.marketplace_enhance_queue
    ORDER BY priority, enqueued_at
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.marketplace_enhance_queue q
  USING pick WHERE q.listing_id = pick.listing_id
  RETURNING q.listing_id;
END;
$function$
;

UPDATE public.admin_automations SET action=jsonb_set(action,'{command}',to_jsonb(
  replace(action->>'command','jsonb_build_object(',
    'jsonb_build_object(''Authorization'', ''Bearer '' || (select decrypted_secret from vault.decrypted_secrets where name=''legacy_anon_key''), ')))
WHERE action->>'command' LIKE '%net.http_post%' AND action->>'command' NOT ILIKE '%Authorization%';
-- Bounded invocations use the current streaming Shopify adapter rather than the old monolithic deployment.
UPDATE public.admin_automations SET action=jsonb_set(action,'{command}',to_jsonb(
  replace(replace(replace(action->>'command','"max_pages":40','"max_pages":2'),
    '"batch_size":60,"concurrency":3','"batch_size":5,"concurrency":1'),
    '"batch_size":20,"concurrency":3','"batch_size":5,"concurrency":1')))
WHERE slug IN ('mp_fill_ohmyfantasy','news_orphan_reclaim');
SELECT public.sync_automations_to_cron(true);

CREATE INDEX IF NOT EXISTS events_image_quality_pool_idx ON public.events(id) WHERE duplicate_of_id IS NULL AND cardinality(coalesce(images,'{}'::text[]))>0;
CREATE OR REPLACE FUNCTION public.claim_event_image_quality_candidates(p_claim_token uuid, p_limit integer DEFAULT 25)
 RETURNS TABLE(event_id uuid, image_url text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_token uuid; v_anchor uuid := gen_random_uuid();
begin
  insert into public.event_quality_worker_leases(worker,lease_token,lease_until,claimed_at)
  values('event-image-quality',p_claim_token,now()+interval '10 minutes',now())
  on conflict(worker) do update set lease_token=excluded.lease_token,
    lease_until=excluded.lease_until,claimed_at=excluded.claimed_at
  where public.event_quality_worker_leases.lease_until<now()
  returning lease_token into v_token;
  if v_token is distinct from p_claim_token then return; end if;

  return query
  with pool as materialized (
    (select * from public.events where id>=v_anchor and duplicate_of_id is null
      and cardinality(coalesce(images,'{}'::text[]))>0 order by id limit 500)
    union all
    (select * from public.events where id<v_anchor and duplicate_of_id is null
      and cardinality(coalesce(images,'{}'::text[]))>0 order by id limit 500)
  )
  select e.id,e.images[1]
  from pool e
  left join public.event_image_quality_observations o
    on o.event_id=e.id and o.image_url=e.images[1]
  where e.duplicate_of_id is null and cardinality(coalesce(e.images,'{}'::text[]))>0
    and public.event_quality_url_is_safe(e.images[1])
    and (o.event_id is null or o.checked_at<greatest(e.updated_at,now()-interval '30 days'))
  order by (o.event_id is null) desc,o.checked_at nulls first,e.updated_at desc,e.id
  limit greatest(0,least(p_limit,100));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.marketplace_image_upscale_worklist(p_limit integer DEFAULT 25, p_source_type text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, source_type text, images text[], served_url text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_anchor uuid := gen_random_uuid();
  v_limit integer := GREATEST(1, LEAST(p_limit, 200));
BEGIN
  RETURN QUERY
  WITH pool AS MATERIALIZED (
    (SELECT l.* FROM public.marketplace_listings l WHERE l.id>=v_anchor
      AND l.status='active' AND l.images IS NOT NULL AND cardinality(l.images)>0
      AND NOT coalesce(l.attributes->'image_upscale' ? 'resolved_at',false)
      AND coalesce((l.attributes->'image_upscale'->>'attempts')::int,0)<3
      ORDER BY l.id LIMIT 500)
    UNION ALL
    (SELECT l.* FROM public.marketplace_listings l WHERE l.id<v_anchor
      AND l.status='active' AND l.images IS NOT NULL AND cardinality(l.images)>0
      AND NOT coalesce(l.attributes->'image_upscale' ? 'resolved_at',false)
      AND coalesce((l.attributes->'image_upscale'->>'attempts')::int,0)<3
      ORDER BY l.id LIMIT 500)
  ), eligible AS (
    (
      SELECT l.id AS lid
      FROM pool l
      WHERE l.id >= v_anchor
        AND l.status = 'active'
        AND l.images IS NOT NULL
        AND cardinality(l.images) > 0
        AND NOT COALESCE(l.attributes->'image_upscale' ? 'resolved_at', false)
        AND COALESCE((l.attributes->'image_upscale'->>'attempts')::int, 0) < 3
        AND (p_source_type IS NULL OR l.source_type = p_source_type)
        AND EXISTS (
          SELECT 1 FROM unnest(l.images) im
          WHERE im ~ '/media/catalog/product/cache/[0-9a-f]{16,}/'
             OR im ~ '/image/cache/.+-\d{2,4}x\d{2,4}\.'
             OR im ~ '/wp-content/uploads/.+-\d{2,4}x\d{2,4}\.'
             OR (im ~ '[?&]width=' AND (im LIKE '%cdn.shopify.com%' OR im LIKE '%/cdn/shop/%'))
             OR (im ~ '[?&](w|h|imwidth|sw|maxwidth)=' AND im NOT LIKE '%cdn.shopify.com%')
        )
      ORDER BY l.id
      LIMIT v_limit
    )
    UNION ALL
    (
      SELECT l.id AS lid
      FROM pool l
      WHERE l.id < v_anchor
        AND l.status = 'active'
        AND l.images IS NOT NULL
        AND cardinality(l.images) > 0
        AND NOT COALESCE(l.attributes->'image_upscale' ? 'resolved_at', false)
        AND COALESCE((l.attributes->'image_upscale'->>'attempts')::int, 0) < 3
        AND (p_source_type IS NULL OR l.source_type = p_source_type)
        AND EXISTS (
          SELECT 1 FROM unnest(l.images) im
          WHERE im ~ '/media/catalog/product/cache/[0-9a-f]{16,}/'
             OR im ~ '/image/cache/.+-\d{2,4}x\d{2,4}\.'
             OR im ~ '/wp-content/uploads/.+-\d{2,4}x\d{2,4}\.'
             OR (im ~ '[?&]width=' AND (im LIKE '%cdn.shopify.com%' OR im LIKE '%/cdn/shop/%'))
             OR (im ~ '[?&](w|h|imwidth|sw|maxwidth)=' AND im NOT LIKE '%cdn.shopify.com%')
        )
      ORDER BY l.id
      LIMIT v_limit
    )
  )
  SELECT l.id, l.source_type, l.images, ia.optimized_url
  FROM eligible e
  JOIN public.marketplace_listings l ON l.id = e.lid
  LEFT JOIN public.image_asset_links k
    ON k.entity_type = 'marketplace_listing' AND k.entity_id = l.id AND k.sort_order = 0
  LEFT JOIN public.image_assets ia
    ON ia.id = k.asset_id AND ia.optimization_status IN ('optimized', 'cdn_optimized')
  LIMIT v_limit;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.marketplace_enhance_refill(p_max integer DEFAULT 5000)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_n integer;
BEGIN
  WITH pool AS MATERIALIZED (
    SELECT * FROM public.marketplace_listings
    WHERE status='active' AND (
      (length(coalesce(btrim(description),''))<=20 AND NOT(coalesce(description_i18n,'{}'::jsonb) ? '_recovery_checked_at'))
      OR (length(coalesce(btrim(description),''))>20 AND NOT(coalesce(description_i18n,'{}'::jsonb) ? '_enhanced_at')))
    ORDER BY id LIMIT greatest(1,least(p_max,500))
  ), boiler AS (
    SELECT md5(lower(btrim(description))) AS h
    FROM pool
    WHERE status='active' AND coalesce(btrim(description),'')<>''
    GROUP BY 1 HAVING count(*)>5
  ), cand AS (
    SELECT ml.id,
      CASE
        WHEN length(coalesce(btrim(ml.description),''))<=20 THEN 0
        WHEN md5(lower(btrim(ml.description))) IN(SELECT h FROM boiler) THEN 1
        WHEN length(btrim(ml.description))<80 THEN 2
        ELSE 3
      END::smallint priority
    FROM pool ml
    WHERE ml.status='active' AND (
      (length(coalesce(btrim(ml.description),''))<=20
        AND NOT (coalesce(ml.description_i18n,'{}'::jsonb) ? '_recovery_checked_at'))
      OR
      (length(coalesce(btrim(ml.description),''))>20
        AND NOT (coalesce(ml.description_i18n,'{}'::jsonb) ? '_enhanced_at'))
    )
    ORDER BY 2,ml.updated_at,ml.id LIMIT greatest(1,p_max)
  )
  INSERT INTO public.marketplace_enhance_queue(listing_id,priority)
  SELECT id,priority FROM cand ON CONFLICT(listing_id) DO NOTHING;
  GET DIAGNOSTICS v_n=ROW_COUNT;
  RETURN v_n;
END;
$function$
;

-- Match the nearest-city KNN expression so the containment query does not sort every city per venue.
CREATE INDEX IF NOT EXISTS cities_coord_knn_idx ON public.cities USING gist
  (extensions.ST_MakePoint(longitude::double precision,latitude::double precision))
WHERE latitude IS NOT NULL AND longitude IS NOT NULL;
CREATE INDEX IF NOT EXISTS venues_reverse_city_pending_idx ON public.venues
  ((coalesce(enrichment_status,'{}'::jsonb) ? 'city_namesake_repair') DESC,
   (category='cruising') ASC NULLS FIRST,id)
WHERE city_id IS NULL AND duplicate_of_id IS NULL AND closed_at IS NULL
  AND coalesce(review_status,'')<>'archived' AND latitude IS NOT NULL AND longitude IS NOT NULL
  AND NOT(coalesce(enrichment_status,'{}'::jsonb) ? 'reverse_city');
-- This nightly full inventory is measured to exceed the default two-minute cron limit.
UPDATE public.admin_automations SET action=jsonb_set(action,'{command}',
  to_jsonb('SET statement_timeout = ''600s''; SELECT public.refresh_business_brand_quality();'::text))
WHERE slug='business_brand_quality_refresh';
SELECT public.sync_automations_to_cron(true);
