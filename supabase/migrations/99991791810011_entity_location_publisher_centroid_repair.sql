create or replace function public.assert_entity_location_consistency()
returns trigger language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare c public.cities; co_code text; point_code text; outside_m float8; v public.venues;
begin
 if new.city_id is not null and new.country_id is not null then
   select * into c from public.cities where id=new.city_id;
   if c.country_id is not null and c.country_id<>new.country_id and not public.geo_countries_equivalent(
     (select code from countries where id=c.country_id),(select code from countries where id=new.country_id)) then
     raise exception 'City and country conflict: choose a city in the selected country' using errcode='23514';
   end if;
 end if;
 if tg_table_name='events' and new.venue_id is not null then
   select * into v from public.venues where id=new.venue_id;
   if v.country_id is not null and new.country_id is not null and v.country_id<>new.country_id
     and not public.geo_countries_equivalent((select code from countries where id=v.country_id),
       (select code from countries where id=new.country_id)) then
     raise exception 'Event and venue country conflict: choose the correct venue' using errcode='23514';
   end if;
   if new.latitude is not null and new.longitude is not null and v.latitude is not null and v.longitude is not null
     and public.haversine_m(new.latitude::numeric,new.longitude::numeric,v.latitude::numeric,v.longitude::numeric)>500000 then
     raise exception 'Event and venue coordinates conflict: choose the correct venue' using errcode='23514';
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
drop trigger zzzz_location_consistency on public.events;
create trigger zzzz_location_consistency before insert or update of city_id,country_id,latitude,longitude,venue_id
on public.events for each row execute function public.assert_entity_location_consistency();
-- Publisher breadcrumbs independently identify the US namesakes. Retract proven
-- coordinates copied from the foreign city; never replace them with another centroid.
-- Sources: https://santafe.gaycities.com/ and https://santacruz.gaycities.com/.
do $$ declare r record; target uuid; us uuid; zone text; after_row jsonb;
begin
 select id into us from public.countries where code='US' and duplicate_of_id is null;
 for r in select e.*,to_jsonb(e) before_data from public.events e join public.cities c on c.id=e.city_id
   join public.countries co on co.id=e.country_id
   where e.duplicate_of_id is null and e.country='US' and co.code in ('AR','BO')
     and (e.website like 'https://santafe.gaycities.com/events/%' or e.website like 'https://santacruz.gaycities.com/events/%')
     and e.field_provenance->'latitude'->>'source'='derived:city_centroid'
     and e.field_provenance->'longitude'->>'source'='derived:city_centroid'
     and public.haversine_m(e.latitude::numeric,e.longitude::numeric,c.latitude::numeric,c.longitude::numeric)<250
 loop
   target:=null;
   select c.id into target from public.cities c
   where c.country_id=us and c.duplicate_of_id is null
     and c.name_normalized=case when r.website like 'https://santafe.%' then 'santa fe' else 'santa cruz' end
     and c.region_code=case when r.website like 'https://santafe.%' then 'US-NM' else 'US-CA' end;
   if target is null then raise exception 'Verified US city missing'; end if;
   zone:=case when r.website like 'https://santafe.%' then 'America/Denver' else 'America/Los_Angeles' end;
   update public.events set country_id=us,city_id=target,latitude=null,longitude=null,timezone=zone,
     venue_id=case when exists(select 1 from public.venues v join public.countries vc on vc.id=v.country_id
       where v.id=r.venue_id and not public.geo_countries_equivalent(vc.code,'US')) then null else r.venue_id end,
     needs_attention=true,
     field_provenance=coalesce(field_provenance,'{}')||jsonb_build_object(
       'latitude',jsonb_build_object('source','retracted_wrong_city_centroid','at',now(),'previous_value',r.latitude),
       'longitude',jsonb_build_object('source','retracted_wrong_city_centroid','at',now(),'previous_value',r.longitude),
       'city_id',jsonb_build_object('source',r.website,'value',target,'at',now()),
       'country_id',jsonb_build_object('source',r.website,'value',us,'at',now()),
       'timezone',jsonb_build_object('source','verified_publisher_city','value',zone,'at',now()))
     where id=r.id returning to_jsonb(events) into after_row;
   if after_row is null or after_row->>'city_id'<>target::text then raise exception 'Publisher location repair blocked'; end if;
   insert into public.entity_location_audit(entity_table,entity_id,source,before_data,patch)
     values('events',r.id,r.website,r.before_data,jsonb_build_object('country_id',us,'city_id',target,'latitude',null,'longitude',null,'timezone',zone));
 end loop;
end $$;
notify pgrst,'reload schema';
