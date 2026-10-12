-- Evidence depends on canonical parent context as well as the row's own pin.
create or replace function public.geo_cms_fingerprint(p_id uuid)
returns text language sql stable set search_path=public,pg_temp as $$
select md5(jsonb_build_array(g.name,g.code,g.latitude,g.longitude,g.parent_id,g.country_id,g.city_id,g.duplicate_of_id,
co.code,ci.name,ci.latitude,ci.longitude,ci.wikidata_qid)::text)
from geo_places g left join countries co on co.id=g.country_id left join cities ci on ci.id=g.city_id where g.id=p_id;
$$;

-- Adopt the expanded fingerprint for still-current checks; preserve stale evidence.
update geo_cms_verifications v set fingerprint=public.geo_cms_fingerprint(v.place_id)
from geo_places g join countries co on co.id=g.country_id
where v.place_id=g.id and v.status<>'stale' and v.checks->>'country_code'=co.code
  and v.fingerprint=md5(jsonb_build_array(g.name,g.latitude,g.longitude,g.parent_id,g.country_id,g.city_id,g.duplicate_of_id)::text);

create or replace function public.geo_cms_invalidate_verification()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if row(new.name,new.code,new.latitude,new.longitude,new.parent_id,new.country_id,new.city_id,new.duplicate_of_id)
     is distinct from row(old.name,old.code,old.latitude,old.longitude,old.parent_id,old.country_id,old.city_id,old.duplicate_of_id) then
    update geo_cms_verifications set status='stale' where place_id=new.id;
    if new.place_type='city' then
      update geo_cms_verifications set status='stale' where place_id in (select id from geo_places where parent_id=new.id);
    elsif new.place_type='country' then
      update geo_cms_verifications set status='stale' where place_id in (select id from geo_places where country_id=new.id);
    end if;
  end if;
  return new;
end $$;

create or replace function public.geo_cms_invalidate_city_identity()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.wikidata_qid is distinct from old.wikidata_qid then
    update geo_cms_verifications set status='stale'
    where place_id=new.id or place_id in (select id from geo_places where city_id=new.id);
  end if;
  return new;
end $$;
revoke all on function public.geo_cms_invalidate_city_identity() from public,anon,authenticated;
create trigger geo_cms_city_identity_stale after update of wikidata_qid on public.cities
for each row execute function public.geo_cms_invalidate_city_identity();
create or replace function public.geo_cms_list_record(p_id uuid)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
select jsonb_build_object(
'id',g.id,'place_type',g.place_type,'name',g.name,'slug',g.slug,'parent_id',g.parent_id,
'country_id',g.country_id,'city_id',g.city_id,'latitude',g.latitude,'longitude',g.longitude,
'updated_at',g.updated_at,'safety_gated',g.safety_gated,'duplicate_of_id',g.duplicate_of_id,
'child_count',(select count(*) from geo_places ch where ch.parent_id=g.id and ch.place_type in ('city','village') and ch.duplicate_of_id is null),
'venue_count',0,'event_count',0,'hotel_count',0,
'path',concat_ws(' > ',case when g.place_type<>'country' then co.name end,case when g.place_type='village' then concat_ws(' ',ci.name,ci.region_code) end,concat_ws(' ',g.name,case when g.place_type='city' then ci.region_code end)),
'country_name',co.name,'country_code',co.code,'city_name',ci.name,'region_code',ci.region_code,'region_name',ci.region_name,
'source_table',case g.place_type when 'country' then 'countries' when 'city' then 'cities' when 'village' then 'queer_villages' end,
'verification_status',case when vf.place_id is not null and vf.fingerprint is distinct from public.geo_cms_fingerprint(g.id) then 'stale' else coalesce(vf.status,'missing') end,'verification',to_jsonb(vf),
'workflow_state',cm.workflow_state,'seo_indexable',g.seo_indexable)
from geo_places g left join countries co on co.id=g.country_id left join cities ci on ci.id=g.city_id
left join geo_cms_verifications vf on vf.place_id=g.id
left join cms_content_metadata cm on cm.source_id=g.id and cm.source_table=case g.place_type when 'country' then 'countries' when 'city' then 'cities' when 'village' then 'queer_villages' end
where g.id=p_id and g.place_type in ('country','city','village');
$$;
revoke all on function public.geo_cms_list_record(uuid) from public,anon,authenticated;
grant execute on function public.geo_cms_list_record(uuid) to service_role;

create or replace function public.geo_cms_record(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_result jsonb;
begin
  perform public.geo_cms_assert_reader();
  select jsonb_build_object(
    'id',g.id,'place_type',g.place_type,'name',g.name,'slug',g.slug,
    'parent_id',g.parent_id,'country_id',g.country_id,'city_id',g.city_id,
    'latitude',g.latitude,'longitude',g.longitude,'updated_at',g.updated_at,
    'safety_gated',g.safety_gated,'duplicate_of_id',g.duplicate_of_id,
    'child_count',(select count(*) from geo_places ch where ch.parent_id=g.id and ch.place_type in ('city','village') and ch.duplicate_of_id is null),
    'venue_count',(select count(*) from venues v where v.duplicate_of_id is null and case g.place_type when 'country' then v.country_id=g.id when 'city' then v.city_id=g.id else v.queer_village_id=g.id end),
    'event_count',(select count(*) from events e where e.duplicate_of_id is null and case g.place_type when 'country' then e.country_id=g.id when 'city' then e.city_id=g.id else e.queer_village_id=g.id end),
    'hotel_count',(select count(*) from hotels h where case g.place_type when 'country' then h.country_id=g.id when 'city' then h.city_id=g.id else h.queer_village_id=g.id end),
    'path',concat_ws(' > ',case when g.place_type<>'country' then co.name end,case when g.place_type='village' then concat_ws(' ',ci.name,ci.region_code) end,concat_ws(' ',g.name,case when g.place_type='city' then ci.region_code end)),
    'country_name',co.name,'country_code',co.code,'city_name',ci.name,'region_code',ci.region_code,'region_name',ci.region_name,
    'source_table',case g.place_type when 'country' then 'countries' when 'city' then 'cities' when 'village' then 'queer_villages' end,
    'verification_status',case when vf.place_id is not null and vf.fingerprint is distinct from public.geo_cms_fingerprint(g.id) then 'stale' else coalesce(vf.status,'missing') end,'verification',to_jsonb(vf),
    'workflow_state',cm.workflow_state,'seo_indexable',g.seo_indexable
  ) into v_result
  from geo_places g left join countries co on co.id=g.country_id left join cities ci on ci.id=g.city_id
  left join geo_cms_verifications vf on vf.place_id=g.id
  left join cms_content_metadata cm on cm.source_id=g.id and cm.source_table=case g.place_type when 'country' then 'countries' when 'city' then 'cities' when 'village' then 'queer_villages' end
  where g.id=p_id and g.place_type in ('country','city','village');
  return v_result;
end $$;
revoke all on function public.geo_cms_record(uuid) from public,anon;
grant execute on function public.geo_cms_record(uuid) to authenticated,service_role;

create or replace function public.geo_cms_browse(p_parent_id uuid default null,p_search text default '',p_type text default null,p_offset int default 0,p_continent_id uuid default null,p_region_id uuid default null,p_status text default null)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_rows jsonb; v_total bigint;
begin
  perform public.geo_cms_assert_reader();
  if p_type is not null and p_type not in ('country','city','village') then raise exception 'Invalid geography type'; end if;
  with matches as (
    select g.id,g.name from geo_places g join countries co on co.id=g.country_id left join geo_cms_verifications vf on vf.place_id=g.id
    where g.place_type in ('country','city','village') and g.duplicate_of_id is null
      and (p_type is null or g.place_type=p_type) and (p_status is null or (case when vf.place_id is not null and vf.fingerprint is distinct from public.geo_cms_fingerprint(g.id) then 'stale' else coalesce(vf.status,'missing') end)=p_status)
      and (p_continent_id is null or co.continent_id=p_continent_id)
      and (p_region_id is null or co.region_id=p_region_id)
      and (case when nullif(btrim(p_search),'') is not null then g.name ilike '%'||btrim(p_search)||'%' or co.name ilike '%'||btrim(p_search)||'%' or exists(select 1 from cities ci where ci.id=g.city_id and ci.name ilike '%'||btrim(p_search)||'%')
        when p_type is not null or p_status is not null then true when p_parent_id is null then g.place_type='country' else g.parent_id=p_parent_id end)
  ), page as (select * from matches order by name,id offset greatest(p_offset,0) limit 50)
  select (select count(*) from matches),coalesce((select jsonb_agg(public.geo_cms_list_record(id) order by name,id) from page),'[]'::jsonb)
  into v_total,v_rows;
  return jsonb_build_object('rows',v_rows,'total',v_total);
end $$;
revoke all on function public.geo_cms_browse(uuid,text,text,int,uuid,uuid,text) from public,anon;
grant execute on function public.geo_cms_browse(uuid,text,text,int,uuid,uuid,text) to authenticated,service_role;



