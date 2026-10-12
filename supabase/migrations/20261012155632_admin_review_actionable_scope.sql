-- Show actionable human work, without duplicating canonical staging/ownership decisions.
create or replace view public.admin_review_src_business_quality with(security_invoker=true) as
 select (md5('business-quality:'||s.id::text)::uuid)::uuid as id,
 ('business-quality')::text as queue_type,
 (s.entity_type)::text as content_type,
 (coalesce(o.name,b.display_name,'Business quality finding'))::text as title,
 (s.reason_code)::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.first_seen_at)::timestamptz as created_at,
 ('business-quality')::text as source,
 (s.entity_id)::uuid as entity_id,
 (case when s.entity_type='organization' then 'organizations' else 'marketplace_brands' end)::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('finding_id',s.id,'evidence',s.evidence,'dimension',s.dimension,'state',s.state,'reason_code',s.reason_code))||jsonb_build_object('workflow','business-quality'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.entity_quality_findings s left join public.organizations o on s.entity_type='organization' and o.id=s.entity_id left join public.marketplace_brands b on s.entity_type='marketplace_brand' and b.id=s.entity_id
 where s.entity_type in ('organization','marketplace_brand') and s.state in ('fail','pending') and s.waived_at is null and s.reason_code not in ('never_verified','logo_lookup_pending') and (o.id is not null or b.id is not null) and not (s.entity_type='marketplace_brand' and s.dimension='ownership' and b.ownership_review_status in ('pending','needs_review'));
revoke all on public.admin_review_src_business_quality from public,anon,authenticated;

create or replace view public.admin_review_src_general_review with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('general-review')::text as queue_type,
 (s.entity_type)::text as content_type,
 (coalesce(c.name,v.name,e.title,o.name,p.name,s.details->>'title',s.details->>'city_name',s.details->>'name',s.review_type))::text as title,
 (replace(lower(s.review_type),'_',' '))::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('general-review')::text as source,
 (s.entity_id)::uuid as entity_id,
 (case s.entity_type when 'city' then 'cities' when 'venue' then 'venues' when 'event' then 'events' when 'organization' then 'organizations' when 'personality' then 'personalities' end)::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('details',s.details,'review_type',s.review_type))||jsonb_build_object('workflow','general-review'))::jsonb as meta,
 (null)::text as flag_type,
 (jsonb_build_object('requires_confirm',s.details->'hard_blocker'='true'::jsonb,'confirm_rejection',s.details->'hard_blocker'='true'::jsonb,'risk',case when s.details->'hard_blocker'='true'::jsonb then 'safety' else 'integrity' end))::jsonb as risk_flags
 from public.review_queue s left join public.cities c on s.entity_type='city' and c.id=s.entity_id and c.duplicate_of_id is null left join public.venues v on s.entity_type='venue' and v.id=s.entity_id and v.duplicate_of_id is null left join public.events e on s.entity_type='event' and e.id=s.entity_id and e.duplicate_of_id is null left join public.organizations o on s.entity_type='organization' and o.id=s.entity_id left join public.personalities p on s.entity_type='personality' and p.id=s.entity_id and p.duplicate_of_id is null
 where s.status in ('pending','open','pending_review','review') and s.entity_type<>'ingestion_staging' and (s.entity_type not in ('city','venue','event','organization','personality') or coalesce(c.id,v.id,e.id,o.id,p.id) is not null);
revoke all on public.admin_review_src_general_review from public,anon,authenticated;

create or replace view public.admin_review_src_geography with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('geography')::text as queue_type,
 (s.place_type)::text as content_type,
 (s.name)::text as title,
 (vf.checks->>'reason')::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (vf.checked_at)::timestamptz as created_at,
 ('geography')::text as source,
 (case when s.place_type='city' then s.city_id else s.id end)::uuid as entity_id,
 (case s.place_type when 'country' then 'countries' when 'city' then 'cities' else 'queer_villages' end)::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('place_id',s.id,'checks',vf.checks,'sources',vf.sources,'fingerprint',vf.fingerprint,'parent_id',s.parent_id))||jsonb_build_object('workflow','geography'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.geo_places s join public.geo_cms_verifications vf on vf.place_id=s.id
 where s.duplicate_of_id is null and s.place_type in ('country','city','village') and (vf.status='review' or vf.status='stale' and (vf.checks->'country_match'='false'::jsonb or vf.checks->>'city_classification' is not null or (vf.checks->>'distance_to_city_m')::numeric>50000));
revoke all on public.admin_review_src_geography from public,anon,authenticated;

create or replace view public.admin_review_src_ai_suggestions with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('ai-suggestions')::text as queue_type,
 (s.entity_type)::text as content_type,
 (coalesce(t.name,s.proposed_value->>'name',s.suggestion_type))::text as title,
 (s.suggestion_type)::text as subtitle,
 ('pending')::text as status,
 (s.confidence)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('ai-suggestions')::text as source,
 (s.entity_id)::uuid as entity_id,
 (s.entity_type)::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('suggestion_type',s.suggestion_type,'current_value',s.current_value,'proposed_value',s.proposed_value,'review_notes',s.review_notes,'source_model',s.source_model))||jsonb_build_object('workflow','ai-suggestions'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.ai_suggestions s left join public.unified_tags t on s.entity_type='unified_tags' and t.id=s.entity_id
 where not coalesce((s.entity_type='unified_tags' or (s.suggestion_type='tag' and s.entity_id is null)),false) and s.status in ('pending','approved') and s.applied_at is null and (s.status='approved' or s.expires_at is null or s.expires_at>now());
revoke all on public.admin_review_src_ai_suggestions from public,anon,authenticated;

create or replace view public.admin_review_src_tag_enrichment with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('tag-enrichment')::text as queue_type,
 (s.entity_type)::text as content_type,
 (coalesce(t.name,s.proposed_value->>'name',s.suggestion_type))::text as title,
 (s.suggestion_type)::text as subtitle,
 ('pending')::text as status,
 (s.confidence)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('tag-enrichment')::text as source,
 (s.entity_id)::uuid as entity_id,
 (s.entity_type)::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('suggestion_type',s.suggestion_type,'current_value',s.current_value,'proposed_value',s.proposed_value,'review_notes',s.review_notes,'source_model',s.source_model))||jsonb_build_object('workflow','tag-enrichment'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.ai_suggestions s left join public.unified_tags t on s.entity_type='unified_tags' and t.id=s.entity_id
 where (s.entity_type='unified_tags' or (s.suggestion_type='tag' and s.entity_id is null)) and s.status in ('pending','approved') and s.applied_at is null and (s.status='approved' or s.expires_at is null or s.expires_at>now());
revoke all on public.admin_review_src_tag_enrichment from public,anon,authenticated;

update public.admin_review_sources set label='Record correctness' where queue_key='general-review';
create or replace function public.admin_review_action(p_queue_type text,p_item_id uuid,p_action text,
 p_notes text default null,p_confirm boolean default false,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.admin_review_sources; v_meta jsonb; v_entity uuid; v_flags jsonb;
 v_result jsonb; v_check jsonb; v_changed integer; v_issue text; v_description text; v_merge uuid; v_tag public.tag_suggestions;
begin
 p_confirm:=coalesce(p_confirm,false); p_payload:=coalesce(p_payload,'{}'::jsonb);
 if auth.uid() is null or not public.has_any_role_jwt(array['admin','moderator','editor']::public.app_role[]) then
  raise exception 'Review decision requires a staff account' using errcode='42501'; end if;
 select * into r from public.admin_review_sources where queue_key=p_queue_type and active;
 if not found or not(public.has_role_jwt('admin'::public.app_role) or
   (r.min_role='moderator' and public.has_role_jwt('moderator'::public.app_role)) or
   (r.min_role='editor' and public.has_any_role_jwt(array['moderator','editor']::public.app_role[]))) then
  raise exception 'You cannot decide this review source' using errcode='42501'; end if;
 if p_action is null or p_action not in ('approve','reject','reopen') then raise exception 'Unsupported review decision'; end if;
 if p_action='reopen' then
  if not r.can_reopen then raise exception 'This decision cannot be undone'; end if;
  v_result:=public.triage_action(p_item_id,p_queue_type,p_action,auth.uid(),p_notes,p_payload->>'canned_slug',false,p_confirm,p_payload);
 else
  -- Serialize decisions across review clients, then recheck pending membership.
  perform pg_advisory_xact_lock(hashtextextended(p_queue_type||':'||p_item_id::text,0));
  if r.lock_table is not null then
   execute format('select id from public.%I where id=$1 for update',r.lock_table) using p_item_id;
  end if;
  execute format('select meta,entity_id,risk_flags from public.%I where id=$1',r.view_name)
   into v_meta,v_entity,v_flags using p_item_id;
  if v_meta is null then raise exception 'This item is no longer pending. Refresh the queue.' using errcode='40001'; end if;
  if (p_action='approve' or p_action='reject' and coalesce((v_flags->>'confirm_rejection')::boolean,false)) and coalesce((v_flags->>'requires_confirm')::boolean,false) and not p_confirm then
   raise exception 'Confirm the consequences before approving this item'; end if;
  case p_queue_type
   when 'org-link-review' then
    v_result:=public.decide_org_adoption(p_item_id,p_action='approve',nullif(p_payload->>'organization_id','')::uuid,p_notes);
   when 'sensitive-tags' then
    perform set_config('app.actor','admin:unified-review',true);
    update public.unified_tags set human_reviewed=true,seo_indexable=p_action='approve',verification_status='reviewed'
     where id=p_item_id and status='active' and not coalesce(human_reviewed,false);
   when 'tags' then
    if p_action='approve' and coalesce((v_flags->>'approve_unsupported')::boolean,false) then
     if not p_confirm then raise exception 'Confirm the tag identities before merging'; end if;
     select * into strict v_tag from public.tag_suggestions where id=p_item_id and status='pending';
     if v_tag.entity_id is null or v_tag.tag_id is null or v_tag.entity_id=v_tag.tag_id then raise exception 'This pair is not a valid tag merge'; end if;
     select id into v_merge from public.tag_merge_review where canonical_id=v_tag.tag_id and duplicate_id=v_tag.entity_id and status='pending' limit 1;
     if v_merge is null then
      insert into public.tag_merge_review(canonical_id,duplicate_id,similarity,reason,status,lexical_variant)
       values(v_tag.tag_id,v_tag.entity_id,coalesce(v_tag.confidence,0),coalesce(v_tag.reason,'Admin-reviewed tag pair'),'pending',false) returning id into v_merge;
     end if;
     perform public.approve_tag_merge(v_merge,auth.uid()::text);
     update public.tag_suggestions set status='approved',reviewed_by=auth.uid(),reviewed_at=now() where id=p_item_id;
    else v_result:=public.triage_action(p_item_id,p_queue_type,p_action,auth.uid(),p_notes,p_payload->>'canned_slug',false,p_confirm,p_payload); end if;
   when 'tag-merges' then
    if p_action='approve' then perform public.approve_tag_merge(p_item_id,auth.uid()::text);
    else perform public.reject_tag_merge(p_item_id,coalesce((p_payload->>'keep_distinct')::boolean,false),auth.uid()::text); end if;
   when 'venue-category' then
    v_result:=public.decide_venue_category(p_item_id,p_action='approve',nullif(p_payload->>'category',''),p_notes);
   when 'venue-kind' then
    v_result:=public.decide_venue_nonvenue(p_item_id,p_action='approve',p_notes,false);
   when 'event-quality' then
    perform public.decide_event_quality_issue(p_item_id,case when p_action='approve' then 'resolved' else 'accepted' end,p_notes);
   when 'liveness' then
    if p_action='approve' then perform public.existence_approve_archive((v_meta->>'audit_id')::bigint);
    else perform public.existence_reject_archive((v_meta->>'audit_id')::bigint,p_notes); end if;
   when 'group-requests' then
    if p_action='approve' then perform public.approve_group_join_request(p_item_id);
    else perform public.reject_group_join_request(p_item_id); end if;
   when 'brand-ownership' then
    if p_action='approve' then v_result:=public.approve_marketplace_brand(p_item_id,
     array(select jsonb_array_elements_text(coalesce(p_payload->'tags','[]'::jsonb))),p_confirm,p_notes);
    else v_result:=public.reject_marketplace_brand(p_item_id,p_notes); end if;
   when 'personality-publication' then
    if p_action='approve' then perform public.freigabe_personality(p_item_id,p_confirm);
    else perform public.reject_personality_capture(p_item_id,coalesce(p_notes,'Rejected after review')); end if;
   when 'tag-restoration' then
    perform public.review_tag_restoration(p_item_id,case when p_action='reject' then 'retire' else coalesce(p_payload->>'decision','utility') end,p_payload->>'description');
   when 'tag-editorial' then
    v_issue:=v_meta->>'issue_code';
    perform set_config('app.actor','admin:unified-review',true);
    if v_issue in ('article_missing_description','article_unreviewed_prose') and p_action='approve' then
     perform public.review_tag_description(v_entity,coalesce(nullif(p_payload->>'description',''),v_meta->>'description'));
    elsif v_issue='article_ontology_unreviewed' and p_action='approve' then
     perform public.review_tag_ontology(v_entity,coalesce(p_payload->>'decision','none_applicable'));
    elsif v_issue='article_localisation_unreviewed' and p_action='approve' then
     perform public.review_tag_translation(v_entity,p_payload->>'locale',p_payload->>'description');
    elsif p_action='reject' then
     if nullif(trim(p_notes),'') is null then raise exception 'Add a reason for retaining this tag as utility vocabulary'; end if;
     update public.unified_tags set publication_role='utility',publication_role_reviewed_at=now(),
      publication_role_review_note=p_notes,seo_indexable=false,seo_deindex_reason='publication_role:utility' where id=v_entity;
    elsif v_issue in ('utility_indexable','redirect_indexable') then
     update public.unified_tags set seo_indexable=false where id=v_entity;
    else raise exception 'Correct the category or source evidence in the editor first, then refresh the queue.'; end if;
   when 'quality-tag' then
    if p_action='approve' then perform public.approve_entity_review(p_item_id,p_notes,p_confirm);
    else perform public.reject_entity_review(p_item_id,p_notes); end if;
   when 'quality-other' then
    if p_action='approve' then perform public.approve_entity_review(p_item_id,p_notes,p_confirm);
    else perform public.reject_entity_review(p_item_id,p_notes); end if;
   when 'milestone-review' then
    if p_action='approve' then
     if v_meta->>'field'='description' then
      if length(trim(coalesce(p_payload->>'description','')))<30 then raise exception 'Write a replacement description before approving'; end if;
      update public.milestone_review_queue set proposed_value=proposed_value||jsonb_build_object('replacement',p_payload->>'description') where id=p_item_id;
     end if;
     perform public.approve_milestone_review(p_item_id,p_notes);
    else perform public.reject_milestone_review(p_item_id,p_notes); end if;
   when 'milestone-links' then
    if p_action='approve' then perform public.approve_milestone_link_proposal(p_item_id,nullif(p_payload->>'role',''));
    else perform public.reject_milestone_link_proposal(p_item_id); end if;
   when 'milestone-duplicates' then
    perform public.decide_milestone_duplicate_candidate(p_item_id,case when p_action='approve' then 'confirmed' else 'dismissed' end,p_notes);
   when 'business-quality' then
    if p_action='reject' then
     v_result:=public.resolve_business_brand_quality_findings(array[(v_meta->>'finding_id')::bigint],'waive',p_notes);
    else
     perform public.refresh_business_brand_quality();
     if exists(select 1 from public.entity_quality_findings where id=(v_meta->>'finding_id')::bigint and state in ('fail','pending') and waived_at is null) then
      raise exception 'The issue is still present. Correct the record before rechecking.'; end if;
    end if;
   when 'trip-geography' then
    if p_action='reject' then raise exception 'Choose the correct destination to resolve this task'; end if;
    if nullif(p_payload->>'city_id','') is null and nullif(p_payload->>'country_id','') is null then
     raise exception 'Choose a city or country before resolving'; end if;
    if nullif(p_payload->>'city_id','') is not null and nullif(p_payload->>'country_id','') is not null and not exists(
     select 1 from public.cities where id=(p_payload->>'city_id')::uuid and country_id=(p_payload->>'country_id')::uuid) then
     raise exception 'The selected city and country do not match'; end if;
    perform public.resolve_trip_geo_review(p_item_id,nullif(p_payload->>'city_id','')::uuid,nullif(p_payload->>'country_id','')::uuid);
   when 'geography' then
    if p_action='reject' then raise exception 'Geographic evidence conflicts must be corrected, not dismissed'; end if;
    v_check:=public.geo_cms_verify((v_meta->>'place_id')::uuid);
    if v_check->>'verification_status' in ('review','missing','stale') then
     raise exception 'Verification still needs evidence or corrections. Open the record editor.'; end if;
   when 'feedback' then
    if p_action='reject' and nullif(trim(p_notes),'') is null then raise exception 'Add a reason for closing this feedback'; end if;
    update public.community_submissions set feedback_status=case when p_action='approve' then 'planned' else 'done' end,
     resolution=case when p_action='reject' then 'wontfix' else null end,reviewed_by=auth.uid(),reviewed_at=now(),
     reviewer_notes=coalesce(p_notes,reviewer_notes),resolved_at=case when p_action='reject' then now() else null end
     where id=p_item_id and feedback_status in ('new','under_review');
   when 'general-review' then
    if nullif(trim(p_notes),'') is null then raise exception 'Add a review note explaining the outcome'; end if;
    update public.review_queue set status=case when p_action='approve' then 'resolved' else 'rejected' end,
     resolved_by=auth.uid(),resolved_at=now(),details=coalesce(details,'{}'::jsonb)||jsonb_build_object('review_note',p_notes) where id=p_item_id;
   when 'cms-issues' then
    if nullif(trim(p_notes),'') is null then raise exception 'Add a review note explaining the outcome'; end if;
    update public.cms_review_queue set resolution=case when p_action='approve' then 'resolved' else 'rejected' end,
     resolved_by=auth.uid(),resolved_at=now(),notes=coalesce(p_notes,notes) where id=p_item_id;
   when 'tag-enrichment' then raise exception 'Enrichment decisions must use the application service';
   when 'ai-suggestions' then raise exception 'Enrichment decisions must use the application service';
   else
    v_result:=public.triage_action(p_item_id,p_queue_type,p_action,auth.uid(),p_notes,p_payload->>'canned_slug',false,p_confirm,p_payload);
  end case;
 end if;
 if v_result->>'ok'='false' or v_result->>'error' is not null then
  raise exception '%',coalesce(v_result->>'error','The source refused this decision'); end if;
 insert into public.admin_review_decisions(queue_key,item_id,actor_id,decision,notes)
  values(p_queue_type,p_item_id,auth.uid(),p_action,p_notes);
 return jsonb_build_object('ok',true,'result',v_result);
end $$;
revoke all on function public.admin_review_action(text,uuid,text,text,boolean,jsonb) from public,anon;
grant execute on function public.admin_review_action(text,uuid,text,text,boolean,jsonb) to authenticated;
create or replace function public.get_admin_review_queue(
 p_queue_types text[] default null,p_content_types text[] default null,p_search text default null,
 p_sort text default 'priority',p_page integer default 1,p_per_page integer default 50,
 p_scope text default 'all') returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_result jsonb; v_page integer:=greatest(1,coalesce(p_page,1));
 v_size integer:=greatest(1,least(100,coalesce(p_per_page,50))); v_search text; v_union text;
begin
 if not public.has_any_role_jwt(array['admin','moderator','editor']::public.app_role[]) then raise exception 'Review queue requires a staff account' using errcode='42501'; end if;
 if p_scope not in ('all','safety','overdue','public') or p_sort not in ('priority','age','confidence') then
  raise exception 'Invalid review filter' using errcode='22023';
 end if;
 v_search:=case when nullif(trim(p_search),'') is not null then
  '%'||replace(replace(replace(lower(trim(p_search)),'\','\\'),'%','\%'),'_','\_')||'%' end;
 select string_agg(format(
  'select u.id,u.queue_type,u.content_type,u.title,u.subtitle,u.created_at,u.confidence_score, case u.risk_flags->>''severity'' when ''critical'' then 4 when ''high'' then 3 else case coalesce(u.risk_flags->>''risk'',%L) when ''safety'' then 2 when ''integrity'' then 1 else 0 end end urgency_rank, %L::text source_label,coalesce(u.risk_flags->>''risk'',%L)::text risk,%L::boolean public_impact,%L::integer sla_hours,%L::integer priority_weight,%L::boolean can_reopen from public.%I u',
  r.risk,r.label,r.risk,r.public_impact,r.sla_hours,r.priority_weight,r.can_reopen,r.view_name),' union all ' order by r.queue_key)
 into v_union from public.admin_review_sources r where r.active and (
  public.has_role_jwt('admin'::public.app_role)
  or (r.min_role='moderator' and public.has_role_jwt('moderator'::public.app_role))
  or (r.min_role='editor' and public.has_any_role_jwt(array['moderator','editor']::public.app_role[])));
 if v_union is null then
  return jsonb_build_object('items','[]'::jsonb,'sources','[]'::jsonb,'total',0,'all_total',0,'overdue_total',0,'safety_total',0,'page',v_page,'per_page',v_size,'updated_at',now());
 end if;
 execute format($query$
 with authorized as materialized (select *,sla_hours is not null and created_at < now()-make_interval(hours=>sla_hours) as overdue
  from (%s) authorized_rows),
 filtered as (select * from authorized u where
  ($1 is null or u.queue_type=any($1)) and
  ($2 is null or u.content_type=any($2)) and
  ($3 is null or lower(coalesce(u.title,'')) like $3 escape '\' or lower(coalesce(u.subtitle,'')) like $3 escape '\') and
  ($4='all' or ($4='safety' and u.risk='safety') or ($4='public' and u.public_impact) or ($4='overdue' and u.overdue))),
 sorted as (select * from filtered order by
  case when $5='priority' then urgency_rank else 0 end desc,
  case when $5='priority' then overdue else false end desc,
  case when $5='priority' then priority_weight else 0 end desc,
  case when $5='confidence' then confidence_score end asc nulls last,
  created_at asc nulls last,queue_type,id limit $6 offset ($7-1)*$6),
 counts as (select queue_type,count(*) n,count(*) filter(where overdue) late from authorized group by queue_type)
 select jsonb_build_object(
  'items',coalesce((select jsonb_agg(public.admin_review_item(s.queue_type,s.id)||to_jsonb(s) order by
   case when $5='priority' then urgency_rank else 0 end desc,
   case when $5='priority' then overdue else false end desc,
   case when $5='priority' then priority_weight else 0 end desc,
   case when $5='confidence' then confidence_score end asc nulls last,
   created_at asc nulls last,queue_type,id) from sorted s),'[]'::jsonb),
  'total',(select count(*) from filtered),'all_total',(select count(*) from authorized),
  'overdue_total',(select count(*) from authorized where overdue),
  'safety_total',(select count(*) from authorized where risk='safety'),
  'sources',coalesce((select jsonb_agg(jsonb_build_object('key',r.queue_key,'label',r.label,'count',coalesce(c.n,0),
    'overdue',coalesce(c.late,0),'risk',r.risk,'can_reopen',r.can_reopen,'can_bulk',coalesce((select (ts.capabilities->>'can_bulk')::boolean from public.triage_sources ts where ts.queue_key=r.queue_key and ts.active),false)) order by r.label)
    from public.admin_review_sources r left join counts c on c.queue_type=r.queue_key where r.active and (
     public.has_role_jwt('admin'::public.app_role) or
     (r.min_role='moderator' and public.has_role_jwt('moderator'::public.app_role)) or
     (r.min_role='editor' and public.has_any_role_jwt(array['moderator','editor']::public.app_role[])))),'[]'::jsonb),
  'page',$7,'per_page',$6,'updated_at',now()) $query$,v_union) into v_result
 using p_queue_types,p_content_types,v_search,p_scope,p_sort,v_size,v_page;
 return v_result;
end $$;
revoke all on function public.get_admin_review_queue(text[],text[],text,text,integer,integer,text) from public,anon;
grant execute on function public.get_admin_review_queue(text[],text[],text,text,integer,integer,text) to authenticated;
