-- A source edit can invalidate a queued fingerprint without touching a geocoded column.
-- Requeue that row's current snapshot instead of retrying the old one forever.
create or replace function public.refresh_stale_entity_location_job(
  p_table text, p_id uuid, p_fingerprint text
)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare r jsonb; current_fingerprint text; complete boolean;
begin
  if p_table not in ('organizations','venues','hotels') then raise exception 'Unsupported entity'; end if;
  execute format('select to_jsonb(t) from public.%I t where id=$1 for update',p_table)
    into r using p_id;
  if r is not null then current_fingerprint:=public.entity_location_fingerprint(r); end if;
  complete:=r is null or r->>'duplicate_of_id' is not null or (
    r->>'country_id' is not null and r->>'city_id' is not null
    and nullif(btrim(r->>'postal_code'),'') is not null
    and r->>'latitude' is not null and r->>'longitude' is not null
    and nullif(btrim(r->>'timezone'),'') is not null);
  update public.entity_location_jobs set
    fingerprint=coalesce(current_fingerprint,fingerprint),
    status=case when complete then 'done' else 'pending' end,
    attempts=0,next_attempt_at=now(),last_error=null,updated_at=now()
  where entity_table=p_table and entity_id=p_id and fingerprint=p_fingerprint;
  return found;
end $$;
revoke all on function public.refresh_stale_entity_location_job(text,uuid,text) from public,anon,authenticated;
grant execute on function public.refresh_stale_entity_location_job(text,uuid,text) to service_role;

-- City and country text are part of the fingerprint, even when their IDs stay the same.
do $$ declare t text; columns_to_watch text; begin
  foreach t in array array['organizations','venues','hotels'] loop
    columns_to_watch:=case when t='organizations' then
      'address,city_id,country_id,postal_code,latitude,longitude,timezone'
      else 'address,city,city_id,country,country_id,postal_code,latitude,longitude,timezone' end;
    execute format('drop trigger if exists zz_location_enqueue on public.%I',t);
    execute format('create trigger zz_location_enqueue after insert or update of %s on public.%I for each row execute function public.enqueue_entity_location()',columns_to_watch,t);
  end loop;
end $$;

