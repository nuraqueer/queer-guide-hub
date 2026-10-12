CREATE OR REPLACE FUNCTION public.assert_entity_location_consistency()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare c public.cities; co_code text; point_code text; outside_m float8; v public.venues;
begin
 if new.city_id is not null and new.country_id is not null then
   select * into c from public.cities where id=new.city_id;
   if c.country_id is not null and c.country_id<>new.country_id and not public.geo_countries_equivalent(
     (select code from countries where id=c.country_id),(select code from countries where id=new.country_id)) then
     raise exception 'City and country conflict: choose a city in the selected country' using errcode='23514';
   end if;
 end if;
 if tg_table_name='events' then
  if new.venue_id is not null then
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
end $function$
;
