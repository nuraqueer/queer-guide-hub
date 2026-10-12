-- A verified official-site address is usable even if no street or coordinates were supplied.
-- Include the site in the snapshot so changing it invalidates in-flight evidence.
create or replace function public.entity_location_fingerprint(p jsonb)
returns text language sql immutable set search_path=public,pg_temp as $$
 select md5(jsonb_build_array(p->'address',p->'city',p->'city_id',p->'country',p->'country_id',
   p->'postal_code',p->'latitude',p->'longitude',p->'timezone',p->'website')::text)
$$;

create or replace function public.enqueue_entity_location()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare p jsonb:=to_jsonb(new); f text;
begin
 if new.duplicate_of_id is not null then return null; end if;
 if new.city_id is not null and new.country_id is not null and nullif(btrim(new.postal_code),'') is not null
   and new.latitude is not null and new.longitude is not null and nullif(btrim(new.timezone),'') is not null then return null; end if;
 if nullif(btrim(new.address),'') is null and (new.latitude is null or new.longitude is null)
   and nullif(btrim(new.website),'') is null then return null; end if;
 -- A linked organisation receives the result from its location. Do not geocode twice.
 if tg_table_name='organizations' then
   if new.primary_venue_id is not null then return null; end if;
 end if;
 f:=public.entity_location_fingerprint(p);
 insert into public.entity_location_jobs(entity_table,entity_id,fingerprint)
 values(tg_table_name,new.id,f)
 on conflict(entity_table,entity_id) do update set fingerprint=excluded.fingerprint,status='pending',attempts=0,
   next_attempt_at=now(),last_error=null,updated_at=now()
 where entity_location_jobs.fingerprint<>excluded.fingerprint;
 return null;
end $$;
revoke all on function public.enqueue_entity_location() from public,anon,authenticated;

do $$ declare t text; columns_to_watch text; begin
  foreach t in array array['organizations','venues','hotels'] loop
    columns_to_watch:=case when t='organizations' then
      'address,city_id,country_id,postal_code,latitude,longitude,timezone,website'
      else 'address,city,city_id,country,country_id,postal_code,latitude,longitude,timezone,website' end;
    execute format('drop trigger if exists zz_location_enqueue on public.%I',t);
    execute format('create trigger zz_location_enqueue after insert or update of %s on public.%I for each row execute function public.enqueue_entity_location()',columns_to_watch,t);
  end loop;
end $$;
