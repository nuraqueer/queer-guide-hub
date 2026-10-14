-- Bound the organization inventory to one resumable cohort per invocation.
CREATE OR REPLACE FUNCTION public.refresh_business_brand_quality()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_findings integer:=0; v_batch integer:=0; v_orgs integer:=0; v_brands integer:=0;
  v_org_ids uuid[]; v_pending bigint;
  v_snapshot bigint; v_stats jsonb; v_by_role jsonb; v_by_brand_state jsonb;
begin
  perform public.reconcile_organization_link_roles();
  perform public.link_brand_organization_domain_matches(500);

  SELECT coalesce(array_agg(id),'{}'::uuid[]) INTO v_org_ids FROM (
    SELECT id FROM public.organizations
    WHERE duplicate_of_id IS NULL AND (quality_checked_at IS NULL
      OR quality_checked_at < now()-interval '1 day' OR updated_at>quality_checked_at)
    ORDER BY quality_checked_at NULLS FIRST,id LIMIT 2000
  ) batch;
  with org as (
    select o.*,
      exists(select 1 from venues v where v.organization_id=o.id and v.duplicate_of_id is null)
      or exists(select 1 from hotels h where h.organization_id=o.id and h.duplicate_of_id is null)
      or exists(select 1 from marketplace_merchants m where m.organization_id=o.id)
      or exists(select 1 from marketplace_brands b where b.organization_id=o.id)
      or exists(select 1 from affiliate_partners a where a.organization_id=o.id)
      or exists(select 1 from news_sources n where n.organization_id=o.id) has_link
    from organizations o where o.id=ANY(v_org_ids)
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
    from entity_quality_findings where entity_type='organization' AND entity_id=ANY(v_org_ids) group by entity_id
  ) update organizations o set quality_dimensions=d.dimensions,quality_checked_at=now(),completeness_score=coalesce(d.score,0),needs_attention=coalesce(d.score,0)<60
    from d where d.entity_id=o.id;
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
      'roles_link_mismatch',(select count(*) from organizations o where o.id=ANY(v_org_ids) and (
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

  SELECT count(*) INTO v_pending FROM public.organizations WHERE duplicate_of_id IS NULL AND (quality_checked_at IS NULL OR quality_checked_at < now()-interval '1 day' OR updated_at>quality_checked_at);
  return jsonb_build_object('organizations_pending',v_pending,'converged',v_pending=0,'items_examined',cardinality(v_org_ids),'findings_upserted',v_findings,'organizations_scored',v_orgs,'brands_scored',v_brands,'snapshot_id',v_snapshot);
end;
$function$
;

CREATE INDEX IF NOT EXISTS organizations_quality_due_idx ON public.organizations(quality_checked_at NULLS FIRST,id)
WHERE duplicate_of_id IS NULL;
UPDATE public.admin_automations SET action=jsonb_build_object('type','cron','jobname','venue_coord_snap',
  'command','SELECT public.run_venue_coord_snap();') WHERE slug='venue_coord_snap';
UPDATE public.admin_automations SET schedule='11-59/15 * * * *', action=jsonb_set(action,'{command}',
  to_jsonb('SELECT public.refresh_business_brand_quality();'::text))
WHERE slug='business_brand_quality_refresh';
-- Restore only repaired jobs whose bounded production checks succeeded.
UPDATE public.admin_automations SET enabled=true,lifecycle_state='active',consecutive_failures=0
WHERE slug IN ('event_image_quality','marketplace_image_upscale','hotel_agentic_enrich',
 'marketplace_link_checker','marketplace_description_enhance','news_orphan_reclaim','push_realtime')
 AND EXISTS(SELECT 1 FROM public.admin_automation_runs r WHERE r.automation_id=admin_automations.id
   AND r.started_at>now()-interval '2 hours' AND r.status='success');
SELECT public.sync_automations_to_cron(true);

