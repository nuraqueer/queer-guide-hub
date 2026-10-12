-- A place-bound record cannot be a duplicate of a record in another country.
-- Keep legacy links readable while rejecting new cross-country merges and edits.
create or replace function public.assert_place_duplicate_country()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare parent_country uuid; child_code text; parent_code text;
begin
  if new.duplicate_of_id is null or new.country_id is null then return new; end if;
  if tg_op='UPDATE' and new.duplicate_of_id is not distinct from old.duplicate_of_id
    and new.country_id is not distinct from old.country_id then return new; end if;
  execute format('select country_id from public.%I where id=$1',tg_table_name)
    into parent_country using new.duplicate_of_id;
  if parent_country is null then return new; end if;
  select code into child_code from public.countries where id=new.country_id;
  select code into parent_code from public.countries where id=parent_country;
  if child_code is not null and parent_code is not null
    and not public.geo_countries_equivalent(child_code,parent_code) then
    raise exception 'Cannot link % duplicates across countries (% versus %)',tg_table_name,child_code,parent_code
      using errcode='23514';
  end if;
  return new;
end $$;
revoke all on function public.assert_place_duplicate_country() from public,anon,authenticated;

do $$ declare t text; begin
  foreach t in array array['events','venues','hotels'] loop
    execute format('create trigger zzzz_duplicate_country before insert or update of duplicate_of_id,country_id on public.%I for each row execute function public.assert_place_duplicate_country()',t);
  end loop;
end $$;

