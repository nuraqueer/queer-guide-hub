-- One authorized pending population for the review list, filters, and badges.
-- Existing triage contracts remain unchanged for older clients.
create table public.admin_review_sources (
 queue_key text primary key, view_name name not null unique, label text not null,
 min_role public.app_role not null default 'admin', risk text not null default 'integrity'
 check(risk in ('routine','integrity','safety')), public_impact boolean not null default true,
 sla_hours integer check(sla_hours>0), priority_weight integer not null default 30,
 can_reopen boolean not null default false, active boolean not null default true
);
alter table public.admin_review_sources enable row level security;
create policy admin_review_sources_read on public.admin_review_sources for select to authenticated
 using (public.has_any_role_jwt(array['admin','moderator','editor']::public.app_role[]));
revoke all on public.admin_review_sources from public,anon,authenticated;
grant select on public.admin_review_sources to authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight,can_reopen,active)
select queue_key,view_name,label,'moderator'::public.app_role,
 case when queue_key in ('moderation','dedup-review','quality-city','quality-venue','quality-personality','quality-marketplace') then 'safety'
 when queue_key='automation' then 'routine' else 'integrity' end,
 sla_hours,priority_weight,coalesce((capabilities->>'can_reopen')::boolean,false),active
from public.triage_sources;
update public.admin_review_sources set public_impact=false where queue_key='automation';
create table public.admin_review_decisions (
 id bigint generated always as identity primary key,queue_key text not null,
 item_id uuid not null,actor_id uuid not null,decision text not null,notes text,
 decided_at timestamptz not null default now()
);
alter table public.admin_review_decisions enable row level security;
create policy admin_review_decisions_read on public.admin_review_decisions for select to authenticated
 using(public.has_role_jwt('admin'::public.app_role));
revoke all on public.admin_review_decisions from public,anon,authenticated;
grant select on public.admin_review_decisions to authenticated;

create view public.admin_review_src_sensitive_tags with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('sensitive-tags')::text as queue_type,
 ('unified_tags')::text as content_type,
 (s.name)::text as title,
 ('Choose whether this tag may be indexed')::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('sensitive-tags')::text as source,
 (s.id)::uuid as entity_id,
 ('unified_tags')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('description',s.description,'category',s.category,'usage_count',s.usage_count,'is_adult',s.is_adult,'is_sensitive',s.is_sensitive))||jsonb_build_object('workflow','sensitive-tags'))::jsonb as meta,
 (null)::text as flag_type,
 (jsonb_build_object('requires_confirm',true))::jsonb as risk_flags
 from public.unified_tags s
 where s.status='active' and (s.is_sensitive or s.is_adult) and not coalesce(s.human_reviewed,false);

revoke all on public.admin_review_src_sensitive_tags from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('sensitive-tags','admin_review_src_sensitive_tags','Sensitive tag visibility','admin','safety',168, 90);

create view public.admin_review_src_ai_suggestions with(security_invoker=true) as
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
 where not coalesce((s.entity_type='unified_tags' or (s.suggestion_type='tag' and s.entity_id is null)),false) and s.status in ('pending','approved') and s.applied_at is null and (s.expires_at is null or s.expires_at>now());
create view public.admin_review_src_tag_enrichment with(security_invoker=true) as
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
 where (s.entity_type='unified_tags' or (s.suggestion_type='tag' and s.entity_id is null)) and s.status in ('pending','approved') and s.applied_at is null and (s.expires_at is null or s.expires_at>now());
revoke all on public.admin_review_src_tag_enrichment from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('tag-enrichment','admin_review_src_tag_enrichment','Tag enrichment','admin','integrity',168,35);


revoke all on public.admin_review_src_ai_suggestions from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('ai-suggestions','admin_review_src_ai_suggestions','Enrichment suggestions','admin','integrity',168, 35);

create view public.admin_review_src_tag_merges with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('tag-merges')::text as queue_type,
 ('unified_tags')::text as content_type,
 (d.name||' → '||c.name)::text as title,
 (s.reason)::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('tag-merges')::text as source,
 (s.canonical_id)::uuid as entity_id,
 ('unified_tags')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((to_jsonb(s)||jsonb_build_object('canonical_name',c.name,'duplicate_name',d.name,'canonical_usage',c.usage_count,'duplicate_usage',d.usage_count))||jsonb_build_object('workflow','tag-merges'))::jsonb as meta,
 (null)::text as flag_type,
 (jsonb_build_object('requires_confirm',true))::jsonb as risk_flags
 from public.tag_merge_review s join public.unified_tags c on c.id=s.canonical_id join public.unified_tags d on d.id=s.duplicate_id
 where s.status='pending';

revoke all on public.admin_review_src_tag_merges from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('tag-merges','admin_review_src_tag_merges','Tag merges','admin','safety',168, 60);

create view public.admin_review_src_venue_category with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('venue-category')::text as queue_type,
 ('venues')::text as content_type,
 (s.name)::text as title,
 (s.enrichment_status->'category_backfill'->>'reason')::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.updated_at)::timestamptz as created_at,
 ('venue-category')::text as source,
 (s.id)::uuid as entity_id,
 ('venues')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('proposal',s.enrichment_status->'category_backfill','description',s.description,'website',s.website,'city',s.city,'country',s.country,'source_tags',(select string_agg(distinct vs.payload->'raw'->>'tags',' · ') from public.venue_sources vs where vs.venue_id=s.id)))||jsonb_build_object('workflow','venue-category'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.venues s
 where s.duplicate_of_id is null and s.closed_at is null and coalesce(s.review_status,'')<>'archived' and s.enrichment_status->'category_backfill'->>'status'='review';

revoke all on public.admin_review_src_venue_category from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('venue-category','admin_review_src_venue_category','Venue categories','admin','integrity',168, 40);

create view public.admin_review_src_venue_kind with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('venue-kind')::text as queue_type,
 ('venues')::text as content_type,
 (s.name)::text as title,
 (s.enrichment_status->'nonvenue_candidate'->>'reason')::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.updated_at)::timestamptz as created_at,
 ('venue-kind')::text as source,
 (s.id)::uuid as entity_id,
 ('venues')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('proposal',s.enrichment_status->'nonvenue_candidate','description',s.description,'website',s.website,'city',s.city,'country',s.country,'source_tags',(select string_agg(distinct vs.payload->'raw'->>'tags',' · ') from public.venue_sources vs where vs.venue_id=s.id)))||jsonb_build_object('workflow','venue-kind'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.venues s
 where s.duplicate_of_id is null and s.closed_at is null and coalesce(s.review_status,'')<>'archived' and s.enrichment_status->'nonvenue_candidate'->>'status'='review';

revoke all on public.admin_review_src_venue_kind from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('venue-kind','admin_review_src_venue_kind','Possible non-venues','admin','integrity',168, 40);

create view public.admin_review_src_event_quality with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('event-quality')::text as queue_type,
 ('events')::text as content_type,
 (e.title)::text as title,
 (s.issue_code)::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.detected_at)::timestamptz as created_at,
 ('event-quality')::text as source,
 (s.event_id)::uuid as entity_id,
 ('events')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('evidence',s.evidence,'severity',s.severity,'issue_code',s.issue_code,'dimension',s.dimension))||jsonb_build_object('workflow','event-quality'))::jsonb as meta,
 (null)::text as flag_type,
 (jsonb_build_object('risk',case when s.severity in ('critical','high') then 'safety' else 'integrity' end))::jsonb as risk_flags
 from public.event_quality_issues s join public.events e on e.id=s.event_id
 where s.status='open' and e.duplicate_of_id is null;

revoke all on public.admin_review_src_event_quality from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('event-quality','admin_review_src_event_quality','Event quality issues','admin','integrity',336, 45);

create view public.admin_review_src_liveness with(security_invoker=true) as
 select (md5('liveness:'||s.id::text)::uuid)::uuid as id,
 ('liveness')::text as queue_type,
 (s.entity_type)::text as content_type,
 (coalesce(v.name,e.title,m.title,'Closure review'))::text as title,
 (s.reason)::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('liveness')::text as source,
 (s.entity_id)::uuid as entity_id,
 (case s.entity_type when 'venue' then 'venues' when 'event' then 'events' else 'marketplace_listings' end)::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('audit_id',s.id,'signals',s.signals,'reason',s.reason))||jsonb_build_object('workflow','liveness'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.entity_existence_audit s left join public.venues v on s.entity_type='venue' and v.id=s.entity_id left join public.events e on s.entity_type='event' and e.id=s.entity_id left join public.marketplace_listings m on s.entity_type='marketplace' and m.id=s.entity_id
 where s.action='flag' and s.reverted_at is null;

revoke all on public.admin_review_src_liveness from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('liveness','admin_review_src_liveness','Closure reviews','admin','integrity',168, 50);

create view public.admin_review_src_group_requests with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('group-requests')::text as queue_type,
 ('community_groups')::text as content_type,
 (g.name)::text as title,
 (s.message)::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('group-requests')::text as source,
 (s.group_id)::uuid as entity_id,
 ('community_groups')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('message',s.message,'applicant_id',s.user_id,'group_name',g.name))||jsonb_build_object('workflow','group-requests'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.group_join_requests s join public.community_groups g on g.id=s.group_id
 where s.status='pending' and exists(select 1 from public.group_memberships gm where gm.group_id=s.group_id and gm.user_id=auth.uid() and gm.role in ('admin','moderator'));

revoke all on public.admin_review_src_group_requests from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('group-requests','admin_review_src_group_requests','Group join requests','moderator','safety',48, 70);

create view public.admin_review_src_brand_ownership with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('brand-ownership')::text as queue_type,
 ('marketplace_brands')::text as content_type,
 (s.display_name)::text as title,
 ('Verify ownership claims before publication')::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('brand-ownership')::text as source,
 (s.id)::uuid as entity_id,
 ('marketplace_brands')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('suggested_tags',s.suggested_tags,'evidence',s.evidence,'sample_url',s.sample_url,'product_count',s.product_count,'detection_source',s.detection_source))||jsonb_build_object('workflow','brand-ownership'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.marketplace_brands s
 where s.ownership_review_status in ('pending','needs_review');

revoke all on public.admin_review_src_brand_ownership from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('brand-ownership','admin_review_src_brand_ownership','Brand ownership','admin','safety',168, 80);

create view public.admin_review_src_personality_publication with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('personality-publication')::text as queue_type,
 ('personalities')::text as content_type,
 (s.name)::text as title,
 ('Held for a human publication decision')::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('personality-publication')::text as source,
 (s.id)::uuid as entity_id,
 ('personalities')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('description',coalesce(s.bio,s.description),'is_adult',s.is_adult,'image_url',s.image_url,'needs_attention',s.needs_attention))||jsonb_build_object('workflow','personality-publication'))::jsonb as meta,
 (null)::text as flag_type,
 (jsonb_build_object('requires_confirm',true))::jsonb as risk_flags
 from public.personalities s
 where s.duplicate_of_id is null and coalesce(s.review_status,'') not in ('archived','rejected') and coalesce(s.visibility,'')<>'public' and (s.needs_attention is true or exists(select 1 from public.personality_review_queue q where q.personality_id=s.id and q.status='open'));

revoke all on public.admin_review_src_personality_publication from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('personality-publication','admin_review_src_personality_publication','Personality publication','admin','safety',168, 70);

create view public.admin_review_src_tag_restoration with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('tag-restoration')::text as queue_type,
 ('unified_tags')::text as content_type,
 (s.name)::text as title,
 (s.restoration_previous_reason)::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('tag-restoration')::text as source,
 (s.id)::uuid as entity_id,
 ('unified_tags')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('description',s.description,'category',s.category,'publication_role',s.publication_role,'previous_reason',s.restoration_previous_reason))||jsonb_build_object('workflow','tag-restoration'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.unified_tags s
 where s.status='active' and s.restoration_review_required;

revoke all on public.admin_review_src_tag_restoration from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('tag-restoration','admin_review_src_tag_restoration','Tag restoration','admin','integrity',168, 40);

create view public.admin_review_tag_editorial_issues with(security_invoker=true) as with base as (
    select t.*,
      exists(select 1 from public.tag_sources s
        where s.tag_id=t.id and coalesce(s.is_public,false)) as has_source,
      exists(select 1 from public.tag_relations r
        where r.source_tag_id=t.id and r.review_status='approved') as has_relation
    from public.unified_tags t where t.status='active'
  ), issues as (
    select b.*,v.issue_code,v.evidence,
      case when b.source_required then 'high'
        when coalesce(b.usage_count,0)>=25 then 'medium' else 'normal' end as risk,
      case v.issue_code
        when 'high_risk_missing_source' then 7000000000
        when 'article_missing_description' then 6000000000
        when 'article_missing_primary_category' then 5000000000
        when 'article_unreviewed_prose' then 4000000000
        when 'article_ontology_unreviewed' then 3000000000
        when 'article_localisation_unreviewed' then 2500000000
        else 2000000000 end + coalesce(b.usage_count,0) as priority
    from base b
    cross join lateral (values
      ('article_missing_description',jsonb_build_object(
        'short_candidate',b.short_description),b.publication_role='article'
          and not public.tag_has_prose(b.description,b.short_description)),
      ('article_missing_primary_category',jsonb_build_object(
        'category_id',b.category_id),b.publication_role='article' and b.category_id is null),
      ('article_unreviewed_prose',jsonb_build_object(
        'prose_reviewed_at',b.prose_reviewed_at),b.publication_role='article'
          and b.description is not null and b.prose_reviewed_at is null),
      ('high_risk_missing_source',jsonb_build_object(
        'reason',b.source_requirement_reason,'status',b.source_review_status),
          b.publication_role='article' and b.source_required and not b.has_source),
      ('article_ontology_unreviewed',jsonb_build_object(
        'ontology_review_status',b.ontology_review_status),b.publication_role='article'
          and b.ontology_review_status='pending' and not b.has_relation),
      ('article_localisation_unreviewed',jsonb_build_object(
        'localisation_review_status',b.localisation_review_status),b.publication_role='article'
          and b.prose_reviewed_at is not null and b.localisation_review_status='pending'),
      ('utility_indexable',jsonb_build_object(
        'seo_indexable',b.seo_indexable),b.publication_role='utility' and b.seo_indexable),
      ('redirect_indexable',jsonb_build_object(
        'seo_indexable',b.seo_indexable),b.publication_role='entity_redirect' and b.seo_indexable)
    ) v(issue_code,evidence,applies)
    where v.applies
  ) select * from issues;
revoke all on public.admin_review_tag_editorial_issues from public,anon,authenticated;

create view public.admin_review_src_tag_editorial with(security_invoker=true) as
 select (md5('tag-editorial:'||s.id::text||':'||s.issue_code)::uuid)::uuid as id,
 ('tag-editorial')::text as queue_type,
 ('unified_tags')::text as content_type,
 (s.name)::text as title,
 (s.issue_code)::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('tag-editorial')::text as source,
 (s.id)::uuid as entity_id,
 ('unified_tags')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('tag_id',s.id,'issue_code',s.issue_code,'evidence',s.evidence,'description',s.description,'short_description',s.short_description,'category_id',s.category_id,'publication_role',s.publication_role,'description_i18n_candidates',s.description_i18n_candidates))||jsonb_build_object('workflow','tag-editorial'))::jsonb as meta,
 (null)::text as flag_type,
 (jsonb_build_object('risk',case when s.risk='high' then 'safety' else 'integrity' end))::jsonb as risk_flags
 from public.admin_review_tag_editorial_issues s
 where true;

revoke all on public.admin_review_src_tag_editorial from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('tag-editorial','admin_review_src_tag_editorial','Glossary editorial','admin','integrity',168, 50);

create view public.admin_review_src_quality_tag with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('quality-tag')::text as queue_type,
 ('unified_tags')::text as content_type,
 (t.name)::text as title,
 (s.field)::text as subtitle,
 ('pending')::text as status,
 (s.confidence)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('quality-tag')::text as source,
 (s.entity_id)::uuid as entity_id,
 ('unified_tags')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('field',s.field,'proposed_value',s.proposed_value,'citations',s.citations))||jsonb_build_object('workflow','quality-tag'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.entity_review_queue s join public.unified_tags t on t.id=s.entity_id
 where s.status='open' and s.entity_type='tag';

revoke all on public.admin_review_src_quality_tag from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('quality-tag','admin_review_src_quality_tag','Tag field proposals','admin','integrity',168, 30);

create view public.admin_review_src_quality_other with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('quality-other')::text as queue_type,
 (s.entity_type)::text as content_type,
 (coalesce(s.proposed_value->>'name',s.entity_type||' proposal'))::text as title,
 (s.field)::text as subtitle,
 ('pending')::text as status,
 (s.confidence)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('quality-other')::text as source,
 (s.entity_id)::uuid as entity_id,
 (null)::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('field',s.field,'proposed_value',s.proposed_value,'citations',s.citations))||jsonb_build_object('workflow','quality-other'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.entity_review_queue s
 where s.status='open' and s.entity_type not in ('city','venue','village','personality','marketplace','tag');

revoke all on public.admin_review_src_quality_other from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('quality-other','admin_review_src_quality_other','Other field proposals','admin','integrity',168, 30);

create view public.admin_review_src_milestone_review with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('milestone-review')::text as queue_type,
 ('milestones')::text as content_type,
 (m.title)::text as title,
 (s.field)::text as subtitle,
 ('pending')::text as status,
 (s.confidence)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('milestone-review')::text as source,
 (s.milestone_id)::uuid as entity_id,
 ('milestones')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('field',s.field,'proposed_value',s.proposed_value,'citations',s.citations))||jsonb_build_object('workflow','milestone-review'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.milestone_review_queue s join public.milestones m on m.id=s.milestone_id
 where s.status='open';

revoke all on public.admin_review_src_milestone_review from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('milestone-review','admin_review_src_milestone_review','Milestone field proposals','admin','integrity',168, 30);

create view public.admin_review_src_milestone_links with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('milestone-links')::text as queue_type,
 ('milestones')::text as content_type,
 (m.title||' → '||coalesce(s.matched_name,s.entity_type))::text as title,
 (s.proposed_role_kind)::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('milestone-links')::text as source,
 (s.milestone_id)::uuid as entity_id,
 ('milestones')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((to_jsonb(s))||jsonb_build_object('workflow','milestone-links'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.milestone_link_proposals s join public.milestones m on m.id=s.milestone_id
 where s.status='pending';

revoke all on public.admin_review_src_milestone_links from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('milestone-links','admin_review_src_milestone_links','Milestone links','admin','integrity',168, 30);

create view public.admin_review_src_milestone_duplicates with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('milestone-duplicates')::text as queue_type,
 ('milestones')::text as content_type,
 (a.title||' ⇄ '||b.title)::text as title,
 ('Compare identity and evidence')::text as subtitle,
 ('pending')::text as status,
 (s.confidence)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('milestone-duplicates')::text as source,
 (s.milestone_id_1)::uuid as entity_id,
 ('milestones')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((to_jsonb(s))||jsonb_build_object('workflow','milestone-duplicates'))::jsonb as meta,
 (null)::text as flag_type,
 (jsonb_build_object('requires_confirm',true))::jsonb as risk_flags
 from public.milestone_duplicate_candidates s join public.milestones a on a.id=s.milestone_id_1 join public.milestones b on b.id=s.milestone_id_2
 where s.status='pending';

revoke all on public.admin_review_src_milestone_duplicates from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('milestone-duplicates','admin_review_src_milestone_duplicates','Milestone duplicates','admin','safety',168, 30);

create view public.admin_review_src_business_quality with(security_invoker=true) as
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
 where s.entity_type in ('organization','marketplace_brand') and s.state in ('fail','pending') and s.waived_at is null;

revoke all on public.admin_review_src_business_quality from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('business-quality','admin_review_src_business_quality','Business quality findings','admin','integrity',168, 25);

create view public.admin_review_src_geography with(security_invoker=true) as
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
 where s.duplicate_of_id is null and s.place_type in ('country','city','village') and vf.status='review';

revoke all on public.admin_review_src_geography from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('geography','admin_review_src_geography','Geography conflicts','admin','safety',168, 65);

create view public.admin_review_src_general_review with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('general-review')::text as queue_type,
 (s.entity_type)::text as content_type,
 (coalesce(s.details->>'title',s.details->>'name',s.review_type))::text as title,
 (s.review_type)::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('general-review')::text as source,
 (s.entity_id)::uuid as entity_id,
 (null)::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('details',s.details,'review_type',s.review_type))||jsonb_build_object('workflow','general-review'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.review_queue s
 where s.status in ('pending','open','pending_review','review');

revoke all on public.admin_review_src_general_review from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('general-review','admin_review_src_general_review','Other review tasks','admin','integrity',168, 35);

create view public.admin_review_src_cms_issues with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('cms-issues')::text as queue_type,
 (coalesce(cm.content_type::text,'cms'))::text as content_type,
 (coalesce(cm.meta_title->>'en',cm.title->>'en',s.review_type))::text as title,
 (s.notes)::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.created_at)::timestamptz as created_at,
 ('cms-issues')::text as source,
 (cm.id)::uuid as entity_id,
 ('cms_content')::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('metadata',s.metadata,'notes',s.notes,'review_type',s.review_type))||jsonb_build_object('workflow','cms-issues'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.cms_review_queue s left join public.cms_content cm on cm.id=s.content_id
 where s.resolved_at is null ;

revoke all on public.admin_review_src_cms_issues from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('cms-issues','admin_review_src_cms_issues','CMS review tasks','admin','integrity',168, 35);

create view public.admin_review_src_feedback with(security_invoker=true) as
 select (s.id)::uuid as id,
 ('feedback')::text as queue_type,
 ('feedback')::text as content_type,
 (coalesce(s.data->>'title',s.data->>'name','Feedback'))::text as title,
 (s.feedback_status)::text as subtitle,
 ('pending')::text as status,
 (null)::numeric as confidence_score,
 (s.submitted_at)::timestamptz as created_at,
 ('feedback')::text as source,
 (null)::uuid as entity_id,
 (null)::text as entity_table,
 (false)::boolean as has_diff,
 (null)::uuid as reporter_id,
 ((jsonb_build_object('description',coalesce(s.data->>'description',s.data->>'content',s.raw_text),'feedback_status',s.feedback_status))||jsonb_build_object('workflow','feedback'))::jsonb as meta,
 (null)::text as flag_type,
 ('{}'::jsonb)::jsonb as risk_flags
 from public.community_submissions s
 where s.content_type='feedback' and s.feedback_status in ('new','under_review');

revoke all on public.admin_review_src_feedback from public,anon,authenticated;
insert into public.admin_review_sources(queue_key,view_name,label,min_role,risk,sla_hours,priority_weight) values('feedback','admin_review_src_feedback','Feedback review','admin','integrity',48, 55);

-- Feedback has its own decision workflow, not a second submission approval.
create view public.admin_review_src_submissions with(security_invoker=true) as
 select * from public.triage_src_submissions where content_type is distinct from 'feedback';
revoke all on public.admin_review_src_submissions from public,anon,authenticated;
update public.admin_review_sources set view_name='admin_review_src_submissions' where queue_key='submissions';

create or replace function public.admin_review_rows()
returns table(id uuid,queue_type text,content_type text,title text,subtitle text,status text,
 confidence_score numeric,created_at timestamptz,source text,entity_id uuid,entity_table text,
 has_diff boolean,reporter_id uuid,meta jsonb,flag_type text,risk_flags jsonb,
 source_label text,risk text,public_impact boolean,sla_hours integer,priority_weight integer,can_reopen boolean)
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_union text;
begin
 if not public.has_any_role_jwt(array['admin','moderator','editor']::public.app_role[]) then
  raise exception 'Review queue requires a staff account' using errcode='42501';
 end if;
 select string_agg(format(
  'select u.*, %L::text, coalesce(u.risk_flags->>''risk'',%L)::text,%L::boolean,%L::integer,%L::integer,%L::boolean from public.%I u',
  r.label,r.risk,r.public_impact,r.sla_hours,r.priority_weight,r.can_reopen,r.view_name),' union all ' order by r.queue_key)
 into v_union from public.admin_review_sources r where r.active and (
  public.has_role_jwt('admin'::public.app_role)
  or (r.min_role='moderator' and public.has_role_jwt('moderator'::public.app_role))
  or (r.min_role='editor' and public.has_any_role_jwt(array['moderator','editor']::public.app_role[])));
 if v_union is not null then return query execute v_union; end if;
end $$;
revoke all on function public.admin_review_rows() from public,anon,authenticated;

create or replace function public.get_admin_review_queue(
 p_queue_types text[] default null,p_content_types text[] default null,p_search text default null,
 p_sort text default 'priority',p_page integer default 1,p_per_page integer default 50,
 p_scope text default 'all') returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_result jsonb; v_page integer:=greatest(1,coalesce(p_page,1));
 v_size integer:=greatest(1,least(100,coalesce(p_per_page,50))); v_search text;
begin
 if p_scope not in ('all','safety','overdue','public') or p_sort not in ('priority','age','confidence') then
  raise exception 'Invalid review filter' using errcode='22023';
 end if;
 v_search:=case when nullif(trim(p_search),'') is not null then
  '%'||replace(replace(replace(lower(trim(p_search)),'\','\\'),'%','\%'),'_','\_')||'%' end;
 with authorized as materialized (select *,sla_hours is not null and created_at < now()-make_interval(hours=>sla_hours) as overdue
  from public.admin_review_rows()),
 filtered as (select * from authorized u where
  (p_queue_types is null or u.queue_type=any(p_queue_types)) and
  (p_content_types is null or u.content_type=any(p_content_types)) and
  (v_search is null or lower(coalesce(u.title,'')) like v_search escape '\' or lower(coalesce(u.subtitle,'')) like v_search escape '\') and
  (p_scope='all' or (p_scope='safety' and u.risk='safety') or (p_scope='public' and u.public_impact) or (p_scope='overdue' and u.overdue))),
 sorted as (select * from filtered order by
  case when p_sort='priority' then case risk when 'safety' then 2 when 'integrity' then 1 else 0 end else 0 end desc,
  case when p_sort='priority' then overdue else false end desc,
  case when p_sort='priority' then priority_weight else 0 end desc,
  case when p_sort='confidence' then confidence_score end asc nulls last,
  created_at asc nulls last,queue_type,id limit v_size offset (v_page-1)*v_size),
 counts as (select queue_type,count(*) n,count(*) filter(where overdue) late from authorized group by queue_type)
 select jsonb_build_object(
  'items',coalesce((select jsonb_agg(to_jsonb(s) order by
   case when p_sort='priority' then case risk when 'safety' then 2 when 'integrity' then 1 else 0 end else 0 end desc,
   case when p_sort='priority' then overdue else false end desc,
   case when p_sort='priority' then priority_weight else 0 end desc,
   case when p_sort='confidence' then confidence_score end asc nulls last,
   created_at asc nulls last,queue_type,id) from sorted s),'[]'::jsonb),
  'total',(select count(*) from filtered),'all_total',(select count(*) from authorized),
  'overdue_total',(select count(*) from authorized where overdue),
  'safety_total',(select count(*) from authorized where risk='safety'),
  'sources',coalesce((select jsonb_agg(jsonb_build_object('key',r.queue_key,'label',r.label,'count',coalesce(c.n,0),
    'overdue',coalesce(c.late,0),'risk',r.risk,'can_reopen',r.can_reopen) order by r.label)
    from public.admin_review_sources r left join counts c on c.queue_type=r.queue_key where r.active and (
     public.has_role_jwt('admin'::public.app_role) or
     (r.min_role='moderator' and public.has_role_jwt('moderator'::public.app_role)) or
     (r.min_role='editor' and public.has_any_role_jwt(array['moderator','editor']::public.app_role[])))),'[]'::jsonb),
  'page',v_page,'per_page',v_size,'updated_at',now()) into v_result;
 return v_result;
end $$;
revoke all on function public.get_admin_review_queue(text[],text[],text,text,integer,integer,text) from public,anon;
grant execute on function public.get_admin_review_queue(text[],text[],text,text,integer,integer,text) to authenticated;

create or replace function public.admin_review_action(p_queue_type text,p_item_id uuid,p_action text,
 p_notes text default null,p_confirm boolean default false,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.admin_review_sources; v_meta jsonb; v_entity uuid; v_flags jsonb;
 v_result jsonb; v_check jsonb; v_changed integer; v_issue text; v_description text;
begin
 if auth.uid() is null or not public.has_any_role_jwt(array['admin','moderator','editor']::public.app_role[]) then
  raise exception 'Review decision requires a staff account' using errcode='42501'; end if;
 select * into r from public.admin_review_sources where queue_key=p_queue_type and active;
 if not found or not(public.has_role_jwt('admin'::public.app_role) or
   (r.min_role='moderator' and public.has_role_jwt('moderator'::public.app_role)) or
   (r.min_role='editor' and public.has_any_role_jwt(array['moderator','editor']::public.app_role[]))) then
  raise exception 'You cannot decide this review source' using errcode='42501'; end if;
 if p_action not in ('approve','reject','reopen') then raise exception 'Unsupported review decision'; end if;
 if p_action='reopen' then
  if not r.can_reopen then raise exception 'This decision cannot be undone'; end if;
  v_result:=public.triage_action(p_item_id,p_queue_type,p_action,auth.uid(),p_notes,p_payload->>'canned_slug',false,p_confirm,p_payload);
 else
  -- Serialize decisions across review clients, then recheck pending membership.
  perform pg_advisory_xact_lock(hashtextextended(p_queue_type||':'||p_item_id::text,0));
  execute format('select meta,entity_id,risk_flags from public.%I where id=$1',r.view_name)
   into v_meta,v_entity,v_flags using p_item_id;
  if v_meta is null then raise exception 'This item is no longer pending. Refresh the queue.' using errcode='40001'; end if;
  if p_action='approve' and coalesce((v_flags->>'requires_confirm')::boolean,false) and not p_confirm then
   raise exception 'Confirm the consequences before approving this item'; end if;
  case p_queue_type
   when 'org-link-review' then
    v_result:=public.decide_org_adoption(p_item_id,p_action='approve',nullif(p_payload->>'organization_id','')::uuid,p_notes);
   when 'sensitive-tags' then
    perform set_config('app.actor','admin:unified-review',true);
    update public.unified_tags set human_reviewed=true,seo_indexable=p_action='approve',verification_status='reviewed'
     where id=p_item_id and status='active' and not coalesce(human_reviewed,false);
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
