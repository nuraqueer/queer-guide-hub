-- Fetch evidence only for the selected page, after counting/sorting lightweight rows.
create or replace function public.admin_review_item(p_queue text,p_id uuid) returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_view name; v_item jsonb;
begin
 select view_name into v_view from public.admin_review_sources where queue_key=p_queue and active;
 if v_view is null then return null; end if;
 execute format('select to_jsonb(u) from public.%I u where id=$1',v_view) into v_item using p_id;
 return v_item;
end $$;
revoke all on function public.admin_review_item(text,uuid) from public,anon,authenticated;
create index if not exists admin_review_business_identity_idx on public.entity_quality_findings
 ((md5('business-quality:'||id::text)::uuid)) where entity_type in ('organization','marketplace_brand') and state in ('fail','pending') and waived_at is null;
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
  'select u.id,u.queue_type,u.content_type,u.title,u.subtitle,u.created_at,u.confidence_score, %L::text source_label,coalesce(u.risk_flags->>''risk'',%L)::text risk,%L::boolean public_impact,%L::integer sla_hours,%L::integer priority_weight,%L::boolean can_reopen from public.%I u',
  r.label,r.risk,r.public_impact,r.sla_hours,r.priority_weight,r.can_reopen,r.view_name),' union all ' order by r.queue_key)
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
  case when $5='priority' then case risk when 'safety' then 2 when 'integrity' then 1 else 0 end else 0 end desc,
  case when $5='priority' then overdue else false end desc,
  case when $5='priority' then priority_weight else 0 end desc,
  case when $5='confidence' then confidence_score end asc nulls last,
  created_at asc nulls last,queue_type,id limit $6 offset ($7-1)*$6),
 counts as (select queue_type,count(*) n,count(*) filter(where overdue) late from authorized group by queue_type)
 select jsonb_build_object(
  'items',coalesce((select jsonb_agg(public.admin_review_item(s.queue_type,s.id)||to_jsonb(s) order by
   case when $5='priority' then case risk when 'safety' then 2 when 'integrity' then 1 else 0 end else 0 end desc,
   case when $5='priority' then overdue else false end desc,
   case when $5='priority' then priority_weight else 0 end desc,
   case when $5='confidence' then confidence_score end asc nulls last,
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
  'page',$7,'per_page',$6,'updated_at',now()) $query$,v_union) into v_result
 using p_queue_types,p_content_types,v_search,p_scope,p_sort,v_size,v_page;
 return v_result;
end $$;
revoke all on function public.get_admin_review_queue(text[],text[],text,text,integer,integer,text) from public,anon;
grant execute on function public.get_admin_review_queue(text[],text[],text,text,integer,integer,text) to authenticated;

