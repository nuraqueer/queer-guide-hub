-- Corrections are a separate, service-only operation from null-only enrichment.
-- The caller must supply source-country + external-geocoder corroboration and an
-- unchanged snapshot; existing coordinates are never rewritten by this operation.
create or replace function public.correct_entity_location_country(p_table text,p_id uuid,p_fingerprint text,
 p_expected_country uuid,p_country uuid,p_city uuid,p_evidence jsonb,p_lat numeric default null,p_lng numeric default null,p_timezone text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r jsonb; after_row jsonb; root_before jsonb; root_after jsonb; code text; old_city_timezone text; assignments text; root_id uuid; replace_pin boolean:=false; old_city_lat numeric; old_city_lng numeric;
begin
 if p_table not in ('venues','events','hotels','organizations') then raise exception 'Unsupported entity'; end if;
 select c.code into code from countries c where c.id=p_country and c.duplicate_of_id is null;
 if code is null or upper(p_evidence->>'countrycode') is distinct from code or nullif(p_evidence->>'source_url','') is null then
   raise exception 'External country evidence required';
 end if;
 execute format('select to_jsonb(t) from public.%I t where id=$1 for update',p_table) into r using p_id;
 if r is null or (r->>'country_id')::uuid is distinct from p_expected_country
   or public.entity_location_fingerprint(r)<>p_fingerprint then return jsonb_build_object('stale',true,'corrected',false); end if;
 if p_city is not null and not public.city_location_evidence_matches(p_city,p_country,
   case when coalesce((p_evidence->>'replace_derived_pin')::boolean,false) then p_lat else coalesce((r->>'latitude')::numeric,p_lat) end,
   case when coalesce((p_evidence->>'replace_derived_pin')::boolean,false) then p_lng else coalesce((r->>'longitude')::numeric,p_lng) end) then raise exception 'City evidence conflicts with country/coordinates'; end if;
 select timezone,latitude,longitude into old_city_timezone,old_city_lat,old_city_lng from cities where id=(r->>'city_id')::uuid;
 if coalesce((p_evidence->>'replace_derived_pin')::boolean,false) then
   if p_lat is null or p_lng is null or nullif(p_evidence->'geocoder'->>'street','') is null
     or nullif(p_evidence->'geocoder'->>'housenumber','') is null or old_city_lat is null or old_city_lng is null
     or public.haversine_m((r->>'latitude')::numeric,(r->>'longitude')::numeric,old_city_lat,old_city_lng)>250 then
     raise exception 'Replacing coordinates requires a proven derived city pin and verified street/house evidence';
   end if;
   replace_pin:=true;
 end if;
 assignments:='country_id=$1,city_id=$2,latitude=case when $10 then $3 else coalesce(t.latitude,$3) end,longitude=case when $10 then $4 else coalesce(t.longitude,$4) end,'
   ||'timezone=case when nullif(trim(t.timezone),'''') is null or t.timezone=$6 then coalesce($5,t.timezone) else t.timezone end,'
   ||'needs_attention=case when $2 is null then true else t.needs_attention end,updated_at=now()';
 if r ? 'field_provenance' then
   assignments:=assignments||',field_provenance=coalesce(t.field_provenance,''{}''::jsonb)||jsonb_build_object(''country_correction'',$7)';
 else
   assignments:=assignments||',enrichment_status=coalesce(t.enrichment_status,''{}''::jsonb)||jsonb_build_object(''country_correction'',$7)';
 end if;
 if r ? 'country' then assignments:=assignments||',country=$8'; end if;
 execute format('update public.%I t set %s where id=$9 returning to_jsonb(t)',p_table,assignments)
 into after_row using p_country,p_city,p_lat,p_lng,p_timezone,old_city_timezone,p_evidence,code,p_id,replace_pin;
 if after_row is null then return jsonb_build_object('corrected',false,'blocked',true); end if;
 insert into entity_location_audit(entity_table,entity_id,source,before_data,patch)
 values(p_table,p_id,p_evidence->>'source_url',r,jsonb_build_object('country_id',after_row->'country_id','city_id',after_row->'city_id','timezone',after_row->'timezone','latitude',after_row->'latitude','longitude',after_row->'longitude'));

 -- A generated organization at this same pin is the venue's location mirror.
 -- Keep independently supplied organization locations out of this correction.
 if p_table='venues' then
   root_id:=(r->>'organization_id')::uuid;
   select to_jsonb(o) into root_before from organizations o where o.id=root_id and o.primary_venue_id=p_id
     and o.country_id=p_expected_country and o.city_id is not distinct from (r->>'city_id')::uuid
     and ((o.latitude is not null and o.longitude is not null
       and public.haversine_m(o.latitude::numeric,o.longitude::numeric,(r->>'latitude')::numeric,(r->>'longitude')::numeric)<1)
       or (o.latitude is null and o.longitude is null and r->>'latitude' is null and r->>'longitude' is null))
     and (o.field_provenance->'location_inheritance'->>'source_id'=p_id::text
       or o.field_provenance->'identity'->>'venue_id'=p_id::text)
     and (o.address is null or lower(trim(o.address))=lower(trim(r->>'address')))
     for update;
   if root_before is not null then
     update organizations set country_id=p_country,city_id=p_city,
       latitude=case when replace_pin then p_lat::float8 else coalesce(latitude,(after_row->>'latitude')::float8) end,longitude=case when replace_pin then p_lng::float8 else coalesce(longitude,(after_row->>'longitude')::float8) end,
       timezone=case when nullif(trim(timezone),'') is null or timezone=old_city_timezone then coalesce(p_timezone,timezone) else timezone end,
       field_provenance=coalesce(field_provenance,'{}')||jsonb_build_object('country_correction',p_evidence||jsonb_build_object('venue_id',p_id)),
       needs_attention=case when p_city is null then true else needs_attention end,updated_at=now()
     where id=root_id returning to_jsonb(organizations) into root_after;
     if root_after is not null then insert into entity_location_audit(entity_table,entity_id,source,before_data,patch)
       values('organizations',root_id,p_evidence->>'source_url',root_before,jsonb_build_object('country_id',p_country,'city_id',p_city)); end if;
   end if;
 end if;
 return jsonb_build_object('corrected',true,'organization_corrected',root_after is not null);
end $$;
revoke all on function public.correct_entity_location_country(text,uuid,text,uuid,uuid,uuid,jsonb,numeric,numeric,text) from public,anon,authenticated;
grant execute on function public.correct_entity_location_country(text,uuid,text,uuid,uuid,uuid,jsonb,numeric,numeric,text) to service_role;
;
